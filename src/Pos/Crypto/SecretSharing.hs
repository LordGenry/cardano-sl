{-# LANGUAGE DeriveGeneric   #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Dummy implementation of VSS. It doesn't have any logic now.

module Pos.Crypto.SecretSharing
       (
         -- * Keys and related.
         VssPublicKey
       , VssKeyPair
       , toVssPublicKey
       , vssKeyGen
       , deterministicVssKeyGen

         -- * Sharing
       , EncShare
       , Secret (..)
       , SecretSharingExtra
       , Share
       , Threshold
       , decryptShare
       , genSharedSecret
       , getValidShares
       , recoverSecret
       , unsafeRecoverSecret
       , verifyEncShare
       , verifyShare
       ) where

import           Crypto.PVSS          (Commitment, DecryptedShare, EncryptedShare,
                                       ExtraGen, KeyPair (..), Point, Threshold)
import           Crypto.Random        (MonadRandom)
import           Data.Binary          (Binary (..))
import           Data.Hashable        (Hashable (..))
import           Data.MessagePack     (MessagePack (..))
import           Data.SafeCopy        (SafeCopy (..), base, deriveSafeCopySimple)
import           Data.Text.Buildable  (Buildable)
import qualified Data.Text.Buildable  as Buildable
import qualified Serokell.Util.Base16 as B16
import           Universum

import           Pos.Util             (getCopyBinary, putCopyBinary)

----------------------------------------------------------------------------
-- Keys
----------------------------------------------------------------------------

-- | This key is used as public key in VSS.
newtype VssPublicKey = VssPublicKey
    { getVssPublicKey :: Point
    } deriving (Show, Eq, Binary)

instance Hashable VssPublicKey where
    hashWithSalt = notImplemented

instance MessagePack VssPublicKey where
    toObject = notImplemented
    fromObject = notImplemented

-- | This key pair is used to decrypt share generated by VSS.
newtype VssKeyPair = VssKeyPair
    { getVssKeyPair :: KeyPair
    } deriving (Show, Eq, Generic)

-- | Extract VssPublicKey from VssKeyPair.
toVssPublicKey :: VssKeyPair -> VssPublicKey
toVssPublicKey (VssKeyPair (KeyPair _ p)) = VssPublicKey p

-- | Generate VssKeyPair using Really Secure™ randomness.
vssKeyGen :: MonadIO m => m VssKeyPair
vssKeyGen = notImplemented

-- | Generate VssKeyPair using given seed.
deterministicVssKeyGen :: ByteString -> VssKeyPair
deterministicVssKeyGen _ = notImplemented

----------------------------------------------------------------------------
-- Types
----------------------------------------------------------------------------

-- | Secret can be split into encrypted shares to be reconstructed later.
newtype Secret = Secret
    { getSecret :: ByteString
    } deriving (Show, Eq, Ord, Binary, Generic)

instance MessagePack Secret

instance Buildable Secret where
    build = B16.formatBase16 . getSecret

-- | Shares can be used to reconstruct Secret.
newtype Share = Share
    { getShare :: DecryptedShare
    } deriving (Show, Eq, Binary)

instance MessagePack Share where
    toObject = notImplemented
    fromObject = notImplemented

instance Buildable Share where
    build _ = "share ¯\\_(ツ)_/¯"

-- | Encrypted share which needs to be decrypted using VssKeyPair first.
newtype EncShare = EncShare
    { getEncShare :: EncryptedShare
    } deriving (Show, Eq, Binary)

instance MessagePack EncShare where
    toObject = notImplemented
    fromObject = notImplemented

instance Buildable EncShare where
    build _ = "encrypted share ¯\\_(ツ)_/¯"

-- | This extra data may be used to verify encrypted share.
data SecretSharingExtra =
    SecretSharingExtra !ExtraGen
                       ![Commitment]
    deriving (Show, Eq, Generic)

instance Binary SecretSharingExtra where

instance MessagePack SecretSharingExtra where
    toObject = notImplemented
    fromObject = notImplemented

----------------------------------------------------------------------------
-- Functions
----------------------------------------------------------------------------

-- | Decrypt share using secret key. Doesn't verify if an encrypted
-- share is valid, for this you need to use verifyEncShare.
decryptShare
    :: MonadRandom m
    => VssKeyPair -> EncShare -> m Share
decryptShare = notImplemented

-- | Generate random secret using MonadRandom and share it between
-- given public keys.
genSharedSecret
    :: MonadRandom m
    => Threshold -> [VssPublicKey] -> m (Secret, SecretSharingExtra, [EncShare])
genSharedSecret = notImplemented

-- | Recover secret if there are enough correct shares.
recoverSecret :: Threshold -> [(EncShare, Point, Share)] -> Maybe Secret
recoverSecret = notImplemented

-- | Recover Secret from shares. Assumes that number of shares is
-- enough to do it. Consider using `getValidRecoveryShares` first or
-- use `recoverSecret`
unsafeRecoverSecret :: [Share] -> Secret
unsafeRecoverSecret = notImplemented

-- | Get #Threshold decrypted shares from given list, or less if there
-- is not enough.
getValidShares :: Threshold -> [(EncShare, Point, Share)] -> [Share]
getValidShares = notImplemented

-- | Verify an encrypted share using SecretSharingExtra.
verifyEncShare :: SecretSharingExtra -> VssPublicKey -> EncShare -> Bool
verifyEncShare = notImplemented

-- | Verify that Share has been decrypted correctly.
verifyShare :: EncShare -> VssPublicKey -> Share -> Bool
verifyShare = notImplemented

----------------------------------------------------------------------------
-- SafeCopy instances
----------------------------------------------------------------------------

instance SafeCopy Point where
    putCopy = putCopyBinary
    getCopy = getCopyBinary "Point"

instance SafeCopy DecryptedShare where
    putCopy = putCopyBinary
    getCopy = getCopyBinary "DecryptedShare"

instance SafeCopy ExtraGen where
    putCopy = putCopyBinary
    getCopy = getCopyBinary "ExtraGen"

instance SafeCopy Commitment where
    putCopy = putCopyBinary
    getCopy = getCopyBinary "Commitment"

instance SafeCopy EncryptedShare where
    putCopy = putCopyBinary
    getCopy = getCopyBinary "EncryptedShare"

deriveSafeCopySimple 0 'base ''VssPublicKey
deriveSafeCopySimple 0 'base ''EncShare
deriveSafeCopySimple 0 'base ''Secret
deriveSafeCopySimple 0 'base ''SecretSharingExtra
deriveSafeCopySimple 0 'base ''Share
