{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}

-- | Server launcher

module Pos.Wallet.Web.Server.Launcher
       ( walletApplication
       , walletServer
       , walletServeImpl
       , walletServerOuts

       , bracketWalletWebDB
       , bracketWalletWS
       ) where

import           Universum

import           Network.Wai                      (Application)
import           Serokell.AcidState.ExtendedState (ExtendedState)
import           Servant.Server                   (Handler, Server, serve)
import           Servant.Utils.Enter              ((:~>) (..), enter)
import           Servant.Swagger.UI               (swaggerSchemaUIServer)

import           Pos.Communication                (OutSpecs, SendActions (..), sendTxOuts)
import           Pos.Core.Context                 (HasCoreConstants)
import           Pos.Wallet.SscType               (WalletSscType)
import           Pos.Wallet.Web.Account           (findKey, myRootAddresses)
import           Pos.Wallet.Web.Api               (WalletSwaggerApi, swaggerWalletApi)
import           Pos.Wallet.Web.Methods.Misc      (swaggerSpec)
import           Pos.Wallet.Web.Mode              (MonadWalletWebMode)
import           Pos.Wallet.Web.Pending           (startPendingTxsResubmitter)
import           Pos.Wallet.Web.Server.Handlers   (servantHandlers)
import           Pos.Wallet.Web.Sockets           (ConnectionsVar, closeWSConnections,
                                                   getWalletWebSockets, initWSConnections,
                                                   launchNotifier, upgradeApplicationWS)
import           Pos.Wallet.Web.State             (closeState, openState)
import           Pos.Wallet.Web.State.Storage     (WalletStorage)
import           Pos.Wallet.Web.Tracking          (syncWalletsWithGState)
import           Pos.Web                          (TlsParams, serveImpl)

-- TODO [CSM-407]: Mixture of logic seems to be here

walletServeImpl
    :: MonadWalletWebMode m
    => m Application     -- ^ Application getter
    -> Word16            -- ^ Port to listen
    -> Maybe TlsParams
    -> m ()
walletServeImpl app =
    serveImpl app "127.0.0.1"

walletApplication
    :: MonadWalletWebMode m
    => m (Server WalletSwaggerApi)
    -> m Application
walletApplication serv = do
    wsConn <- getWalletWebSockets
    walletServer <- serv
    let server = (swaggerSchemaUIServer swaggerSpec) :<|> walletServer
    upgradeApplicationWS wsConn . serve swaggerWalletApi server

walletServer
    :: forall m.
       ( MonadWalletWebMode m )
    => SendActions m
    -> m (m :~> Handler)
    -> m (Server WalletSwaggerApi)
walletServer sendActions nat = do
    syncWalletsWithGState @WalletSscType =<< mapM findKey =<< myRootAddresses
    startPendingTxsResubmitter sendActions
    nat >>= launchNotifier
    -- swaggerSchemaUIServer swaggerSpec :<|> ((`enter` servantHandlers sendActions) <$> nat)
    (`enter` servantHandlers sendActions) <$> nat

bracketWalletWebDB
    :: ( MonadIO m
       , MonadMask m
       , HasCoreConstants
       )
    => FilePath  -- ^ Path to wallet acid-state
    -> Bool      -- ^ Rebuild flag for acid-state
    -> (ExtendedState WalletStorage -> m a)
    -> m a
bracketWalletWebDB daedalusDbPath dbRebuild =
    bracket (openState dbRebuild daedalusDbPath)
            closeState

bracketWalletWS
    :: ( MonadIO m
       , MonadMask m
       )
    => (ConnectionsVar -> m a)
    -> m a
bracketWalletWS = bracket initWS closeWSConnections
  where
    initWS = putText "walletServeImpl initWsConnection" >> initWSConnections

walletServerOuts :: OutSpecs
walletServerOuts = sendTxOuts
