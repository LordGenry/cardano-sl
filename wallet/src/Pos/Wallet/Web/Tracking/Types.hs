module Pos.Wallet.Web.Tracking.Types
       ( SyncQueue
       , SyncRequest  (..)
       , TrackingOperation (..)
       , SyncError (..)
       , BlockLockMode
       , WalletTrackingEnv
       , WalletTrackingEnvRead

       -- * Combinators & smart constructors
       , newRestoreRequest
       , newSyncRequest
       , submitSyncRequest
       ) where

import           Universum

import           Control.Concurrent.STM (TBQueue, writeTBQueue)
import           System.Wlog (WithLogger)

import           Pos.Core (HasConfiguration)
import           Pos.DB.Class (MonadDBRead (..))
import           Pos.Slotting (MonadSlotsData)
import           Pos.StateLock (StateLock)
import           Pos.Txp (MonadTxpMem)
import           Pos.Util (HasLens (..))

import           Pos.Wallet.WalletMode (WalletMempoolExt)
import           Pos.Wallet.Web.ClientTypes (CId, Wal)
import           Pos.Wallet.Web.Error.Types (WalletError (..))
import           Pos.Wallet.Web.State (MonadWalletDB)
import qualified Pos.Wallet.Web.State as WS
import           Pos.Wallet.Web.Tracking.Decrypt (WalletDecrCredentials)

type BlockLockMode ctx m =
     ( WithLogger m
     , MonadDBRead m
     , MonadReader ctx m
     , HasLens StateLock ctx StateLock
     , MonadMask m
     )

type WalletTrackingEnvRead ctx m =
     ( BlockLockMode ctx m
     , MonadTxpMem WalletMempoolExt ctx m
     , WS.MonadWalletDBRead ctx m
     , MonadSlotsData ctx m
     , WithLogger m
     , HasConfiguration
     )

type WalletTrackingEnv ctx m =
     ( WalletTrackingEnvRead ctx m
     , MonadWalletDB ctx m
     )

-- | A 'SyncQueue' is a bounded queue where we store incoming 'SyncRequest', and
-- we process them asynchronously.
type SyncQueue = TBQueue SyncRequest

-- | A 'SyncRequest' model the interaction the user (or more generally the system)
-- has with the wallet.
data SyncRequest = SyncRequest {
      srOperation   :: !TrackingOperation
    , srCredentials :: !WalletDecrCredentials
    }

data TrackingOperation = SyncWallet
                       -- ^ Sync the wallet @history@ and @balance@ with the blockchain as
                       -- in "what have I missed while offline". Start from the latest 'HeaderHash'
                       -- the given wallet is synced with, but do not process more than 'BlockBatchSize'
                       -- block.
                       | RestoreWallet
                       -- ^ Restore the full wallet @history@ as in "restoring a wallet
                       -- from seed."
                       deriving Eq

newRestoreRequest :: WalletDecrCredentials -> SyncRequest
newRestoreRequest creds = SyncRequest RestoreWallet creds

newSyncRequest :: WalletDecrCredentials -> SyncRequest
newSyncRequest creds = SyncRequest SyncWallet creds


-- | An enumerations of the errors the syncing process can yield.
-- Such errors are handled internally at the moment, where an error is just logged and flushed away,
-- but could be later exposed to the frontend to offer more fine-grained diagnostics.
data SyncError = GenesisBlockHeaderNotFound
               -- ^ Fetching the genesis block header failed.
               | GenesisHeaderHashNotFound
               -- ^ Fetching the genesis header hash failed.
               | NoSyncTipAvailable (CId Wal)
               -- ^ There was no sync tip available for this wallet.
               | NotSyncable (CId Wal) WalletError
               -- ^ The given wallet cannot be synced due to an unexpected error.
               -- The routine was not even started.
               | SyncFailed  (CId Wal) SomeException
               -- ^ The sync process failed abruptly during the sync process.

-- | Submit a 'SyncRequest' to the asynchronous worker.
submitSyncRequest :: ( MonadIO m
                     , MonadReader ctx m
                     , HasLens SyncQueue ctx SyncQueue
                     ) => SyncRequest -> m ()
submitSyncRequest syncRequest = do
    requestQueue <- view (lensOf @(TBQueue SyncRequest))
    atomically $ writeTBQueue requestQueue syncRequest