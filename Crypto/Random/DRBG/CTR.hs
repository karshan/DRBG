{-# LANGUAGE TupleSections #-}
module Crypto.Random.DRBG.CTR
    ( State
    , getCounter
    , reseedInterval
    , update
    , instantiate
    , reseed
    , generate
    ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Crypto.Classes
import Data.Serialize
import Crypto.Types
import Crypto.Random.DRBG.Types
import Data.Word (Word64)

data State a = St { counter     :: {-# UNPACK #-} !Word64
                  , value       :: !(IV a)
                  , key         :: a
                  }

instance Serialize a => Serialize (State a) where
    get = do c <- getWord64be
             v <- get
             k <- get
             return $ St c (IV v) k
    put (St c (IV v) k) = putWord64be c >> put v >> put k

-- |Get a count of how many times this generator has been used since
-- instantiation or reseed.
getCounter :: State a -> Word64
getCounter = counter

-- |Update the RNG
update :: BlockCipher a => ByteString -> State a -> Maybe (State a)
update provided_data st
    | B.length provided_data < seedLen = Nothing
    | otherwise =
        let (temp,_) = ctr (key st) (value st) (B.replicate seedLen 0)
            (keyBytes,valBytes) = B.splitAt keyLen (zwp' temp provided_data)
            newValue = IV valBytes
            newKey   = buildKey keyBytes
        in St (counter st) newValue `fmap` newKey
  where
    keyLen  = keyLengthBytes `for` key st
    blkLen  = blockSizeBytes `for` key st
    seedLen = keyLen + blkLen
{-# INLINEABLE update #-}

-- | Instantiate a new CTR based counter.  This assumes the block cipher is
-- safe for generating 2^48 seperate bitstrings (e.g. For SP800-90 we
-- assume AES and not 3DES)
instantiate :: BlockCipher a => Entropy -> PersonalizationString -> Maybe (State a)
instantiate ent perStr = st
  where
  seedLen   = blockLen + keyLen
  blockLen  = blockSizeBytes `for` keyOfState st
  keyLen    = keyLengthBytes `for` keyOfState st
  temp      = B.take seedLen (B.append perStr (B.replicate seedLen 0))
  seedMat   = zwp' ent temp
  key0      = buildKey (B.replicate keyLen 0)
  v0        = IV (B.replicate blockLen 0)
  st        = do k <- key0
                 update seedMat (St 1 v0 k)
{-# INLINABLE instantiate #-}

keyOfState :: Maybe (State a) -> a
keyOfState = const undefined

-- |@reseed oldRNG entropy additionalInfo@
--
-- Reseed a DRBG with some entropy ('ent' must be at least seedlength, which is the
-- block length plus the key length)
reseed :: BlockCipher a => State a -> Entropy -> AdditionalInput -> Maybe (State a)
reseed st0 ent ai = st1
  where
  seedLen = (blockSizeBytes `for` key st0) +
            (keyLengthBytes `for` key st0)
  newAI   = B.take seedLen (B.append ai (B.replicate seedLen 0))
  seedMat = zwp' ent newAI
  st1     = update seedMat (st0 { counter = 1} )
{-# INLINABLE reseed #-}

-- |Generate new bytes of data, stepping the generator.
generate :: BlockCipher a => State a -> ByteLength -> AdditionalInput -> Maybe (RandomBits, State a)
generate st0 len ai0
  | counter st0 > reseedInterval = Nothing
  | not (B.null ai0) =
      let aiNew = B.take seedLen (B.append ai0 (B.replicate seedLen 0))
      in do st' <- update aiNew st0
            go st' aiNew
  | otherwise = go st0 (B.replicate seedLen 0)
  where
  outLen  = blockSizeBytes `for` key st0
  keyLen  = keyLengthBytes `for` key st0
  seedLen = outLen + keyLen
  -- go :: BlockCipher a => State a
  --                     -> AdditionalInput
  --                     -> Maybe (RandomBits, State a)
  go st ai =
      let (temp,v2) = ctr (key st) (value st) (B.replicate len 0)
          st1       = update ai (st { value = v2
                                    , counter = counter st + 1 })
      in fmap (temp,) st1
{-# INLINABLE generate #-}

-- |The reseed interval
reseedInterval :: Word64
reseedInterval = 2^48
