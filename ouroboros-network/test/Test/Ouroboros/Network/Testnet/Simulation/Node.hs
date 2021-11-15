{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Test.Ouroboros.Network.Testnet.Simulation.Node
  ( SimArgs
  , MultiNodeScript (..)
  , multinodeSim
  ) where

import           Control.Monad (replicateM)
import           Control.Monad.Class.MonadAsync
                   ( MonadAsync(Async, withAsync, waitAny) )
import           Control.Monad.Class.MonadFork ( MonadFork )
import           Control.Monad.Class.MonadST ( MonadST )
import           Control.Monad.Class.MonadSTM.Strict
                   ( MonadSTM(STM), MonadLabelledSTM )
import           Control.Monad.Class.MonadTime ( MonadTime, DiffTime )
import           Control.Monad.Class.MonadTimer ( MonadTimer )
import           Control.Monad.Class.MonadThrow
                   ( MonadMask, MonadThrow, MonadCatch,
                     MonadEvaluate )
import           Control.Tracer (nullTracer)

import qualified Data.ByteString.Lazy as BL
import           Data.IP (toIPv4, IP (..), toIPv6)
import           Data.List ((\\))
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Void (Void)
import           System.Random (StdGen, mkStdGen)

import           Network.DNS (Domain)

import           Ouroboros.Network.Driver.Limits
                   (ProtocolSizeLimits(..), ProtocolTimeLimits (..))
import           Ouroboros.Network.Mux (MiniProtocolLimits(..))
import           Ouroboros.Network.NodeToNode.Version (DiffusionMode (..))
import           Ouroboros.Network.Protocol.ChainSync.Codec
                   (byteLimitsChainSync, timeLimitsChainSync,
                      ChainSyncTimeout (..))
import           Ouroboros.Network.Protocol.Handshake.Version (Accept (Accept))
import           Ouroboros.Network.Protocol.KeepAlive.Codec
                   (byteLimitsKeepAlive, timeLimitsKeepAlive)
import           Ouroboros.Network.Protocol.Limits (shortWait, smallByteLimit)
import           Ouroboros.Network.PeerSelection.Governor
                   (PeerSelectionTargets (..))
import           Ouroboros.Network.PeerSelection.LedgerPeers
                   (LedgerPeersConsensusInterface (..), UseLedgerAfter (..))
import           Ouroboros.Network.PeerSelection.RootPeersDNS (DomainAccessPoint (..),
                   LookupReqs (..), RelayAccessPoint (..), PortNumber)
import           Ouroboros.Network.PeerSelection.Types (PeerAdvertise (..))
import           Ouroboros.Network.Server.RateLimiting
                   (AcceptedConnectionsLimit (..))
import           Ouroboros.Network.Snocket (TestAddress (..))

import           Ouroboros.Network.Testing.ConcreteBlock (Block)
import           Ouroboros.Network.Testing.Data.Script (Script (..))
import           Simulation.Network.Snocket
                   ( withSnocket,
                   BearerInfo (..) )

import           Test.Ouroboros.Network.Diffusion.Node.NodeKernel (NtNAddr, randomBlockGenerationArgs, BlockGeneratorArgs)
import           Test.Ouroboros.Network.PeerSelection.RootPeersDNS (DNSTimeout,
                   DNSLookupDelay)
import qualified Test.Ouroboros.Network.Diffusion.Node.NodeKernel    as Node
import qualified Test.Ouroboros.Network.Diffusion.Node.MiniProtocols as Node
import qualified Test.Ouroboros.Network.Diffusion.Node               as Node

import           Test.QuickCheck
                   ( Arbitrary(arbitrary),
                     Gen,
                     choose,
                     chooseInt,
                     sized,
                     vectorOf,
                     suchThat, oneof
                   )

-- | Diffusion Simulator Arguments
--
-- Contains all necessary randomly generated values needed to run diffusion in
-- simulation.
--
type SimArgs =
  ( -- randomBlockGenerationArgs arguments
    DiffTime
  , StdGen
  , Int
    -- LimitsAndTimeouts arguments
  , Maybe DiffTime
    -- Interfaces values
  , [RelayAccessPoint]
  , StdGen
  , Map Domain [IP]
    -- Arguments values
  , NtNAddr
  , [(Int, Map RelayAccessPoint PeerAdvertise)]
  , PeerSelectionTargets
  , Script DNSTimeout
  , Script DNSLookupDelay
  )

-- | Multinode Diffusion Simulator Script
--
-- List of 'SimArgs'. Each element of the list represents one running node.
--
newtype MultiNodeScript = MultiNodeScript
  { dMNSToRun :: [SimArgs]
  } deriving Show


instance Arbitrary MultiNodeScript where
  arbitrary = sized $ \size -> do
    raps <- vectorOf size arbitrary `suchThat` any isRelayAccessAddress
    dMap <- genDomainMap raps
    toRun <- mapM (addressToRun raps dMap)
                 [ (ntnToPeerAddr ip p, r)
                 | r@(RelayAccessAddress ip p) <- raps ]
    return (MultiNodeScript toRun)
    where
      isRelayAccessAddress :: RelayAccessPoint -> Bool
      isRelayAccessAddress (RelayAccessAddress _ _) = True
      isRelayAccessAddress _                        = False

      -- | Generate DNS table
      genDomainMap :: [RelayAccessPoint] -> Gen (Map Domain [IP])
      genDomainMap raps = do
        let domains = [ d | RelayAccessDomain d _ <- raps ]
        m <- mapM (\d -> do
          size <- chooseInt (1, 5)
          ips <- vectorOf size genIP
          return (d, ips)) domains

        return (Map.fromList m)

        where
          genIP :: Gen IP
          genIP =
            let genIPv4 = IPv4 . toIPv4 <$> replicateM 4 (choose (0,255))
                genIPv6 = IPv6 . toIPv6 <$> replicateM 8 (choose (0,0xffff))
             in oneof [genIPv4, genIPv6]

      -- | Generate Local Root Peers
      --
      -- Only 1 group is generated
      genLocalRootPeers :: [RelayAccessPoint]
                        -> RelayAccessPoint
                        -> Gen [(Int, Map RelayAccessPoint PeerAdvertise)]
      genLocalRootPeers l r = do
        let newL = l \\ [r]
            size = length newL
        target <- chooseInt (1, size)
        peerAdvertise <- vectorOf size arbitrary
        let mapRelays = Map.fromList $ zip newL peerAdvertise

        return [(target, mapRelays)]

      -- | Given a NtNAddr generate the necessary things to run in Simulation
      addressToRun :: [RelayAccessPoint]
                   -> Map Domain [IP]
                   -> (NtNAddr, RelayAccessPoint)
                   -> Gen SimArgs
      addressToRun raps dMap (ntnAddr, rap) = do
        bgaSlotDuration <- fromInteger <$> choose (0, 100)
        bgaSeed <- mkStdGen <$> arbitrary
        quota <- chooseInt (0, 100)

        -- These values approximately correspond to false positive
        -- thresholds for streaks of empty slots with 99% probability,
        -- 99.9% probability up to 99.999% probability.
        -- t = T_s [log (1-Y) / log (1-f)]
        -- Y = [0.99, 0.999...]
        --
        -- T_s = slot length of 1s.
        -- f = 0.05
        -- The timeout is randomly picked per bearer to avoid all bearers
        -- going down at the same time in case of a long streak of empty
        -- slots. TODO: workaround until peer selection governor.
        -- Taken from ouroboros-consensus/src/Ouroboros/Consensus/Node.hs
        mustReplyTimeout <- Just <$> oneof (pure <$> [90, 135, 180, 224, 269])

        stdGen <- mkStdGen <$> arbitrary

        lrp <- genLocalRootPeers raps rap

        peerSelectionTargets <- arbitrary
        dnsTimeout <- arbitrary
        dnsLookupDelay <- arbitrary

        return ( bgaSlotDuration
               , bgaSeed
               , quota
               , mustReplyTimeout
               , raps
               , stdGen
               , dMap
               , ntnAddr
               , lrp
               , peerSelectionTargets
               , dnsTimeout
               , dnsLookupDelay
               )

-- | Run an arbitrary topology
multinodeSim :: forall m. ( MonadAsync m
                         , MonadFork m
                         , MonadST m
                         , MonadEvaluate m
                         , MonadLabelledSTM m
                         , MonadCatch       m
                         , MonadMask        m
                         , MonadTime        m
                         , MonadTimer       m
                         , MonadThrow  (STM m)
                         , Eq (Async m Void)
                         , forall a. Semigroup a => Semigroup (m a)
                         )
                      => Script (Script BearerInfo)
                      -> MultiNodeScript
                      -> m Void
multinodeSim
  script
  (MultiNodeScript args) = withAsyncAll (map runNode args) $ \nodes -> do
    (_, x) <- waitAny nodes
    return x
  where
    runNode :: SimArgs -> m Void
    runNode ( bgaSlotDuration
            , bgaSeed
            , quota
            , mustReplyTimeout
            , raps
            , stdGen
            , dMap
            , rap
            , lrp
            , peerSelectionTargets
            , dnsTimeout
            , dnsLookupDelay
            ) =
      withSnocket nullTracer script
        $ \ntnSnocket _ -> withSnocket nullTracer script
        $ \ntcSnocket _ ->
          let acceptedConnectionsLimit =
                AcceptedConnectionsLimit maxBound maxBound 0
              diffusionMode = InitiatorAndResponderDiffusionMode
              readPRP = return []
              readULA = return (UseLedgerAfter 0)

              acceptVersion = \_ v -> Accept v

              defaultMiniProtocolsLimit :: MiniProtocolLimits
              defaultMiniProtocolsLimit =
                MiniProtocolLimits { maximumIngressQueue = 64000 }

              blockGeneratorArgs :: BlockGeneratorArgs Block StdGen
              blockGeneratorArgs =
                randomBlockGenerationArgs bgaSlotDuration
                                          bgaSeed
                                          quota

              stdChainSyncTimeout :: ChainSyncTimeout
              stdChainSyncTimeout = do
                  ChainSyncTimeout
                    { canAwaitTimeout  = shortWait
                    , intersectTimeout = shortWait
                    , mustReplyTimeout
                    }

              limitsAndTimeouts :: Node.LimitsAndTimeouts Block
              limitsAndTimeouts
                = Node.LimitsAndTimeouts
                    defaultMiniProtocolsLimit
                    (byteLimitsChainSync (const 0))
                    (timeLimitsChainSync stdChainSyncTimeout)
                    defaultMiniProtocolsLimit
                    (byteLimitsKeepAlive (const 0))
                    timeLimitsKeepAlive
                    defaultMiniProtocolsLimit
                    (ProtocolSizeLimits (const smallByteLimit) (const 0))
                    (ProtocolTimeLimits (const (Just 60)))
                    defaultMiniProtocolsLimit
                    (ProtocolSizeLimits (const (4 * 1440))
                                        (fromIntegral . BL.length))
                    (ProtocolTimeLimits (const shortWait))

              interfaces :: Node.Interfaces m
              interfaces =
                Node.Interfaces ntnSnocket
                                acceptVersion
                                ((return .) <$> domainResolver raps dMap)
                                ntcSnocket
                                stdGen
                                dMap
                                (LedgerPeersConsensusInterface
                                   $ \_ -> return Nothing)

              arguments :: Node.Arguments m
              arguments =
                Node.Arguments rap
                               acceptedConnectionsLimit
                               diffusionMode
                               0
                               0
                               peerSelectionTargets
                               (return lrp)
                               readPRP
                               readULA
                               5
                               30
                               dnsTimeout
                               dnsLookupDelay

           in Node.run blockGeneratorArgs limitsAndTimeouts interfaces arguments
    domainResolver :: [RelayAccessPoint]
                   -> Map Domain [IP]
                   -> LookupReqs
                   -> [DomainAccessPoint]
                   -> Map DomainAccessPoint (Set NtNAddr)
    domainResolver raps dMap _ daps = do
      let domains    = [ (d, p) | RelayAccessDomain d p <- raps ]
          domainsAP  = uncurry DomainAccessPoint <$> domains
          mapDomains = [ ( DomainAccessPoint d p
                         , Set.fromList
                         $ uncurry ntnToPeerAddr
                         <$> zip (dMap Map.! d) (repeat p)
                         )
                       | DomainAccessPoint d p <- domainsAP \\ daps
                       , Map.member d dMap
                       ]
      Map.fromList mapDomains


ntnToPeerAddr :: IP -> PortNumber -> NtNAddr
ntnToPeerAddr a b = TestAddress (Node.IPAddr a b)

withAsyncAll :: MonadAsync m => [m a] -> ([Async m a] -> m b) -> m b
withAsyncAll xs0 action = go [] xs0
  where
    go as []     = action (reverse as)
    go as (x:xs) = withAsync x (\a -> go (a:as) xs)
