{-# LANGUAGE RankNTypes #-}

module Pos.Ssc.Worker
       ( sscWorkers
       ) where

import           Universum

import           Control.Concurrent.STM (readTVar)
import           Control.Lens (at, each, partsOf, to, views)
import           Control.Monad.Except (runExceptT)
import qualified Data.HashMap.Strict as HM
import qualified Data.List.NonEmpty as NE
import           Data.Time.Units (Microsecond, Millisecond, convertUnit)
import           Formatting (build, ords, sformat, shown, (%))
import           Mockable (currentTime, delay)
import           Serokell.Util.Exceptions ()
import           Serokell.Util.Text (listJson)
import qualified System.Metrics.Gauge as Metrics
import qualified Test.QuickCheck as QC

import           Pos.Arbitrary.Ssc ()
import           Pos.Binary.Class (AsBinary, asBinary, fromBinary)
import           Pos.Binary.Infra ()
import           Pos.Binary.Ssc ()
import           Pos.Core (EpochIndex, SlotId (..), StakeholderId,
                           Timestamp (..), VssCertificate (..), VssCertificatesMap (..),
                           blkSecurityParam, bvdMpcThd, getOurSecretKey, getOurStakeholderId,
                           getSlotIndex, lookupVss, memberVss, mkLocalSlotIndex, mkVssCertificate,
                           slotSecurityParam, vssMaxTTL)
import           Pos.Core.Ssc (InnerSharesMap, Opening, SignedCommitment, getCommitmentsMap)
import           Pos.Crypto (SecretKey, VssKeyPair, VssPublicKey, randomNumber, runSecureRandom)
import           Pos.Crypto.Configuration (protocolMagic)
import           Pos.Crypto.SecretSharing (toVssPublicKey)
import           Pos.DB (gsAdoptedBVData)
import           Pos.Diffusion.Types (Diffusion (..))
import           Pos.Lrc.Consumer.Ssc (getSscRichmen)
import           Pos.Lrc.Types (RichmenStakes)
import           Pos.Recovery.Info (recoveryCommGuard)
import           Pos.Reporting.MemState (HasMisbehaviorMetrics (..), MisbehaviorMetrics (..))
import           Pos.Slotting (defaultOnNewSlotParams, getCurrentSlot, getSlotStartEmpatically,
                               onNewSlot)
import           Pos.Ssc.Base (genCommitmentAndOpening, isCommitmentIdx, isOpeningIdx, isSharesIdx,
                               mkSignedCommitment)
import           Pos.Ssc.Behavior (SscBehavior (..), SscOpeningParams (..), SscSharesParams (..))
import           Pos.Ssc.Configuration (mpcSendInterval)
import           Pos.Ssc.Functions (hasCommitment, hasOpening, hasShares, vssThreshold)
import           Pos.Ssc.Logic (sscGarbageCollectLocalData, sscProcessCertificate,
                                sscProcessCommitment, sscProcessOpening, sscProcessShares)
import           Pos.Ssc.Message (SscTag (..))
import           Pos.Ssc.Mode (SscMode)
import qualified Pos.Ssc.SecretStorage as SS
import           Pos.Ssc.Shares (getOurShares)
import           Pos.Ssc.State (getGlobalCerts, getStableCerts, sscGetGlobalState)
import           Pos.Ssc.Toss (computeParticipants, computeSharesDistrPure)
import           Pos.Ssc.Types (HasSscContext (..), scBehavior, scParticipateSsc, scVssKeyPair,
                                sgsCommitments)
import           Pos.Util.AssertMode (inAssertMode)
import           Pos.Util.Trace (Trace)
import           Pos.Util.Trace.Unstructured (LogItem, logDebugS, logErrorS, logInfoS,
                                              logWarningS)
import           Pos.Util.Trace.Wlog (LogNamed, named)
import           Pos.Util.Util (getKeys, leftToPanic)

sscWorkers
  :: ( SscMode ctx m
     , HasMisbehaviorMetrics ctx
     )
  => Trace m (LogNamed LogItem) 
  -> [Diffusion m -> m ()]
sscWorkers namedLogTrace = 
    [ onNewSlotSsc namedLogTrace
    , checkForIgnoredCommitmentsWorker (named namedLogTrace)
    ]

shouldParticipate 
    :: SscMode ctx m
    => Trace m LogItem
    -> EpochIndex
    -> m Bool
shouldParticipate logTrace epoch = do
    richmen <- getSscRichmen "shouldParticipate" epoch
    participationEnabled <- view sscContext >>=
        atomically . readTVar . scParticipateSsc
    ourId <- getOurStakeholderId
    let enoughStake = ourId `HM.member` richmen
    when (participationEnabled && not enoughStake) $
        logDebugS logTrace"Not enough stake to participate in MPC"
    return (participationEnabled && enoughStake)

-- CHECK: @onNewSlotSsc
-- #checkNSendOurCert
onNewSlotSsc
    :: ( SscMode ctx m
       )
    => Trace m (LogNamed LogItem)
    -> Diffusion m
    -> m ()
onNewSlotSsc namedLogTrace = \diffusion -> onNewSlot defaultOnNewSlotParams $ \slotId ->
    recoveryCommGuard logTrace "onNewSlot worker in SSC" $ do
        sscGarbageCollectLocalData slotId
        whenM (shouldParticipate logTrace $ siEpoch slotId) $ do
            behavior <- view sscContext >>=
                atomically . readTVar . scBehavior
            checkNSendOurCert logTrace (sendSscCert diffusion)
            onNewSlotCommitment logTrace slotId (sendSscCommitment diffusion)
            onNewSlotOpening logTrace (sbSendOpening behavior) slotId (sendSscOpening diffusion)
            onNewSlotShares logTrace (sbSendShares behavior) slotId (sendSscShares diffusion)
    where   
        logTrace = named namedLogTrace

-- CHECK: @checkNSendOurCert
-- Checks whether 'our' VSS certificate has been announced
checkNSendOurCert
    :: forall ctx m.
       ( SscMode ctx m
       )
    => Trace m LogItem
    -> (VssCertificate -> m ())
    -> m ()
checkNSendOurCert logTrace sendCert = do
    ourId <- getOurStakeholderId
    let sendCertDo resend slot = do
            if resend then
                logErrorS logTrace "Our VSS certificate is in global state, but it has already expired, \
                         \apparently it's a bug, but we are announcing it just in case."
                else logInfoS logTrace 
                         "Our VssCertificate hasn't been announced yet or TTL has expired, \
                         \we will announce it now."
            ourVssCertificate <- getOurVssCertificate slot
            sscProcessOurMessage logTrace (sscProcessCertificate logTrace ourVssCertificate)
            _ <- sendCert ourVssCertificate
            logDebugS logTrace "Announced our VssCertificate."

    slMaybe <- getCurrentSlot
    case slMaybe of
        Nothing -> pass
        Just sl -> do
            globalCerts <- getGlobalCerts sl
            let ourCertMB = lookupVss ourId globalCerts
            case ourCertMB of
                Just ourCert
                    | vcExpiryEpoch ourCert >= siEpoch sl ->
                        logDebugS logTrace 
                            "Our VssCertificate has been already announced."
                    | otherwise -> sendCertDo True sl
                Nothing -> sendCertDo False sl
  where
    getOurVssCertificate :: SlotId -> m VssCertificate
    getOurVssCertificate slot =
        -- TODO: do this optimization
        -- localCerts <- VCD.certs <$> sscRunLocalQuery (view ldCertificates)
        getOurVssCertificateDo slot mempty
    getOurVssCertificateDo :: SlotId -> VssCertificatesMap -> m VssCertificate
    getOurVssCertificateDo slot certs = do
        ourId <- getOurStakeholderId
        case lookupVss ourId certs of
            Just c -> return c
            Nothing -> do
                ourSk <- getOurSecretKey
                ourVssKeyPair <- getOurVssKeyPair
                let vssKey = asBinary $ toVssPublicKey ourVssKeyPair
                    createOurCert =
                        mkVssCertificate protocolMagic ourSk vssKey .
                        (+) (vssMaxTTL - 1) . siEpoch
                return $ createOurCert slot

getOurVssKeyPair :: SscMode ctx m => m VssKeyPair
getOurVssKeyPair = views sscContext scVssKeyPair

-- Commitments-related part of new slot processing
onNewSlotCommitment
    :: ( SscMode ctx m
       )
    => Trace m LogItem
    -> SlotId
    -> (SignedCommitment -> m ())
    -> m ()
onNewSlotCommitment logTrace slotId@SlotId {..} sendCommitment
    | not (isCommitmentIdx siSlot) = pass
    | otherwise = do
        ourId <- getOurStakeholderId
        shouldSendCommitment <- andM
            [ not . hasCommitment ourId <$> sscGetGlobalState
            , memberVss ourId <$> getStableCerts siEpoch]
        if shouldSendCommitment then
            logDebugS "We should send commitment"
        else
            logDebugS "We shouldn't send commitment"
        when shouldSendCommitment $ do
            ourCommitment <- SS.getOurCommitment siEpoch
            let stillValidMsg = "We shouldn't generate secret, because we have already generated it"
            case ourCommitment of
                Just comm -> logDebugS logTrace stillValidMsg >> sendOurCommitment comm
                Nothing   -> onNewSlotCommDo
  where
    onNewSlotCommDo = do
        ourSk <- getOurSecretKey
        logDebugS logTrace $ sformat ("Generating secret for "%ords%" epoch") siEpoch
        generated <- generateAndSetNewSecret logTrace ourSk slotId
        case generated of
            Nothing -> logWarningS logTrace "I failed to generate secret for SSC"
            Just comm -> do
              logInfoS logTrace (sformat ("Generated secret for "%ords%" epoch") siEpoch)
              sendOurCommitment comm

    sendOurCommitment comm = do
        sscProcessOurMessage logTrace (sscProcessCommitment comm)
        sendOurData logTrace sendCommitment CommitmentMsg comm siEpoch 0

-- Openings-related part of new slot processing
onNewSlotOpening
    :: ( SscMode ctx m
       )
    => Trace m LogItem
    -> SscOpeningParams
    -> SlotId
    -> (Opening -> m ())
    -> m ()
onNewSlotOpening logTrace params SlotId {..} sendOpening
    | not $ isOpeningIdx siSlot = pass
    | otherwise = do
        ourId <- getOurStakeholderId
        globalData <- sscGetGlobalState
        unless (hasOpening ourId globalData) $
            case globalData ^. sgsCommitments . to getCommitmentsMap . at ourId of
                Nothing -> logDebugS logTrace noCommMsg
                Just _  -> SS.getOurOpening siEpoch >>= \case
                    Nothing   -> logWarningS logTrace noOpenMsg
                    Just open -> sendOpeningDo ourId open
  where
    noCommMsg =
        "We're not sending opening, because there is no commitment \
        \from us in global state"
    noOpenMsg =
        "We don't know our opening, maybe we started recently"
    sendOpeningDo ourId open = do
        mbOpen' <- case params of
            SscOpeningNone   -> pure Nothing
            SscOpeningNormal -> pure (Just open)
            SscOpeningWrong  -> Just <$> liftIO (QC.generate QC.arbitrary)
        whenJust mbOpen' $ \open' -> do
            sscProcessOurMessage logTrace (sscProcessOpening logTrace ourId open')
            sendOurData logTrace sendOpening OpeningMsg open' siEpoch 2

-- Shares-related part of new slot processing
onNewSlotShares
    :: ( SscMode ctx m
       )
    => Trace m LogItem
    -> SscSharesParams
    -> SlotId
    -> (InnerSharesMap -> m ())
    -> m ()
onNewSlotShares logTrace params SlotId {..} sendShares = do
    ourId <- getOurStakeholderId
    -- Send decrypted shares that others have sent us
    shouldSendShares <- do
        sharesInBlockchain <- hasShares ourId <$> sscGetGlobalState
        return $ isSharesIdx siSlot && not sharesInBlockchain
    when shouldSendShares $ do
        ourVss <- views sscContext scVssKeyPair
        sendSharesDo ourId =<< getOurShares ourVss logTrace 
  where
    sendSharesDo ourId shares = do
        let shares' = case params of
                SscSharesNone   -> mempty
                SscSharesNormal -> shares
                SscSharesWrong  ->
                    -- Take the list of items in the map, reverse it, put
                    -- items back. NB: this is different from “map reverse”!
                    -- We don't reverse lists of shares, we reassign those
                    -- lists to different keys.
                    shares & partsOf each %~ reverse
        unless (HM.null shares') $ do
            let lShares = fmap (map asBinary) shares'
            sscProcessOurMessage logTrace (sscProcessShares logTrace ourId lShares)
            sendOurData logTrace sendShares SharesMsg lShares siEpoch 4

sscProcessOurMessage
    :: (Buildable err, SscMode ctx m)
    => Trace m LogItem -> m (Either err ()) -> m ()
sscProcessOurMessage logTrace action =
    action >>= logResult
  where
    logResult (Right _) = logDebugS logTrace "We have accepted our message"
    logResult (Left er) =
        logWarningS logTrace $
        sformat ("We have rejected our message, reason: "%build) er

sendOurData
    :: SscMode ctx m
    => Trace m LogItem
    -> (contents -> m ())
    -> SscTag
    -> contents
    -> EpochIndex
    -> Word16
    -> m ()
sendOurData logTrace sendIt msgTag dt epoch slMultiplier = do
    -- Note: it's not necessary to create a new thread here, because
    -- in one invocation of onNewSlot we can't process more than one
    -- type of message.
    waitUntilSend logTrace msgTag epoch slMultiplier
    logInfoS logTrace $ sformat ("Announcing our "%build) msgTag
    _ <- sendIt dt
    logDebugS logTrace $ sformat ("Sent our " %build%" to neighbors") msgTag

-- Generate new commitment and opening and use them for the current
-- epoch. It is also saved in persistent storage.
--
-- Nothing is returned if node is not ready (usually it means that
-- node doesn't have recent enough blocks and needs to be
-- synchronized).
generateAndSetNewSecret
    :: forall ctx m.
       ( SscMode ctx m
       )
    => Trace m LogItem
    -> SecretKey
    -> SlotId -- ^ Current slot
    -> m (Maybe SignedCommitment)
generateAndSetNewSecret logTrace sk SlotId {..} = do
    richmen <- getSscRichmen "generateAndSetNewSecret" siEpoch
    certs <- getStableCerts siEpoch
    inAssertMode $ do
        let participantIds =
                HM.keys . getVssCertificatesMap $
                computeParticipants (getKeys richmen) certs
        logDebugS logTrace $
            sformat ("generating secret for: " %listJson) $ participantIds
    let participants = nonEmpty $
                       map (second vcVssKey) $
                       HM.toList . getVssCertificatesMap $
                       computeParticipants (getKeys richmen) certs
    maybe (Nothing <$ warnNoPs) (generateAndSetNewSecretDo richmen) participants
  where
    here s = "generateAndSetNewSecret: " <> s
    warnNoPs = logWarningS logTrace (here "can't generate, no participants")
    generateAndSetNewSecretDo :: RichmenStakes
                              -> NonEmpty (StakeholderId, AsBinary VssPublicKey)
                              -> m (Maybe SignedCommitment)
    generateAndSetNewSecretDo richmen ps = do
        let onLeft er =
                Nothing <$
                logWarningS logTrace
                (here $ sformat ("Couldn't compute shares distribution, reason: "%build) er)
        mpcThreshold <- bvdMpcThd <$> gsAdoptedBVData
        distrET <- runExceptT (computeSharesDistrPure richmen mpcThreshold)
        flip (either onLeft) distrET $ \distr -> do
            logDebugS logTrace $ here $ sformat ("Computed shares distribution: "%listJson) (HM.toList distr)
            let threshold = vssThreshold $ sum $ toList distr
            let multiPSmb = nonEmpty $
                            concatMap (\(c, x) -> replicate (fromIntegral c) x) $
                            NE.map (first $ flip (HM.lookupDefault 0) distr) ps
            case multiPSmb of
                Nothing -> Nothing <$
                    logWarningS logTrace (here "Couldn't compute participant's vss")
                Just multiPS -> case mapM fromBinary multiPS of
                    Left err -> Nothing <$
                        logErrorS logTrace (here ("Couldn't deserialize keys: " <> err))
                    Right keys -> do
                        (comm, open) <- liftIO $ runSecureRandom $
                            genCommitmentAndOpening threshold keys
                        let signedComm = mkSignedCommitment protocolMagic sk siEpoch comm
                        SS.putOurSecret signedComm open siEpoch
                        pure (Just signedComm)

randomTimeInInterval
    :: SscMode ctx m
    => Microsecond -> m Microsecond
randomTimeInInterval interval =
    -- Type applications here ensure that the same time units are used.
    (fromInteger @Microsecond) <$>
    liftIO (runSecureRandom (randomNumber n))
  where
    n = toInteger @Microsecond interval

waitUntilSend
    :: SscMode ctx m
    => Trace m LogItem -> SscTag -> EpochIndex -> Word16 -> m ()
waitUntilSend logTrace msgTag epoch slMultiplier = do
    let slot =
            leftToPanic "waitUntilSend: " $
            mkLocalSlotIndex $ slMultiplier * fromIntegral slotSecurityParam
    Timestamp beginning <-
        getSlotStartEmpatically $
        SlotId {siEpoch = epoch, siSlot = slot}
    curTime <- currentTime
    let minToSend = curTime
    let maxToSend = beginning + mpcSendInterval
    when (minToSend < maxToSend) $ do
        let delta = maxToSend - minToSend
        timeToWait <- randomTimeInInterval delta
        let ttwMillisecond :: Millisecond
            ttwMillisecond = convertUnit timeToWait
        logDebugS logTrace $
            sformat
                ("Waiting for " %shown % " before sending " %build)
                ttwMillisecond
                msgTag
        delay timeToWait

----------------------------------------------------------------------------
-- Security check
----------------------------------------------------------------------------

checkForIgnoredCommitmentsWorker
    :: forall ctx m.
       ( SscMode ctx m
       , HasMisbehaviorMetrics ctx
       )
    => Trace m LogItem
    -> Diffusion m
    -> m ()
checkForIgnoredCommitmentsWorker logTrace = \_ -> do
    counter <- newTVarIO 0
    onNewSlot defaultOnNewSlotParams (checkForIgnoredCommitmentsWorkerImpl logTrace counter)

-- This worker checks whether our commitments appear in blocks. This check
-- is done only if we actually should participate in SSC. It's triggered if
-- there are 'mdNoCommitmentsEpochThreshold' consequent epochs during which
-- we had to participate in SSC, but our commitment didn't appear in blocks.
-- If check fails, it's reported as non-critical misbehavior.
--
-- The first argument is a counter which is incremented every time we
-- detect unexpected absence of our commitment and is reset to 0 when
-- our commitment appears in blocks.
checkForIgnoredCommitmentsWorkerImpl
    :: forall ctx m.
       ( SscMode ctx m
       , HasMisbehaviorMetrics ctx
       )
    => Trace m LogItem -> TVar Word -> SlotId -> m ()
checkForIgnoredCommitmentsWorkerImpl logTrace counter SlotId {..}
    -- It's enough to do this check once per epoch near the end of the epoch.
    | getSlotIndex siSlot /= 9 * fromIntegral blkSecurityParam = pass
    | otherwise =
        recoveryCommGuard logTrace "checkForIgnoredCommitmentsWorker" $
        whenM (shouldParticipate logTrace siEpoch) $ do
            ourId <- getOurStakeholderId
            globalCommitments <-
                getCommitmentsMap . view sgsCommitments <$> sscGetGlobalState
            case globalCommitments ^. at ourId of
                Nothing -> do
                    -- `modifyTVar'` returns (), hence not used
                    newCounterValue <-
                        atomically $ do
                            !x <- succ <$> readTVar counter
                            x <$ writeTVar counter x
                    whenJustM (view misbehaviorMetrics) $ liftIO .
                        flip Metrics.set (fromIntegral newCounterValue) . _mmIgnoredCommitments
                Just _ -> atomically $ writeTVar counter 0
