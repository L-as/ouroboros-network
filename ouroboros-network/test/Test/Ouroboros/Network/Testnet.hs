{-# LANGUAGE RankNTypes #-}
module Test.Ouroboros.Network.Testnet
  ( tests
  ) where

import           Control.Monad.IOSim

import           Data.List (intercalate)
import           Data.Void (Void)

import           Ouroboros.Network.Testing.Data.Script (Script (..))
import           Ouroboros.Network.Testing.Data.AbsBearerInfo
                   (AbsBearerInfoScript (..), AbsBearerInfo(..), delay,
                   attenuation, toSduSize)
import           Simulation.Network.Snocket
                   ( BearerInfo (..) )

import           Test.Ouroboros.Network.Testnet.Simulation.Node
                   (MultiNodeScript, multinodeSim)

import           Test.QuickCheck
                   ( Property,
                     counterexample
                   )
import           Test.Tasty
import           Test.Tasty.QuickCheck (testProperty)

tests :: TestTree
tests =
  testGroup "Ouroboros.Network.Testnet"
  [ testGroup "multinodeSim"
    [ testProperty "test"
                   test
    ]
  ]

test :: Script AbsBearerInfoScript
     -> MultiNodeScript
     -> Property
test abiScript dmnScript =
    let trace = traceEvents
              $ runSimTrace sim
     in counterexample (intercalate "\n"
                       $ map show
                       $ take 1000 trace)
                       True
  where
    sim :: forall s . IOSim s Void
    sim = multinodeSim ((toBearerInfo <$>) . unBIScript <$> abiScript) dmnScript

toBearerInfo :: AbsBearerInfo -> BearerInfo
toBearerInfo abi =
    BearerInfo {
        biConnectionDelay      = delay (abiConnectionDelay abi),
        biInboundAttenuation   = attenuation (abiInboundAttenuation abi),
        biOutboundAttenuation  = attenuation (abiOutboundAttenuation abi),
        biInboundWriteFailure  = abiInboundWriteFailure abi,
        biOutboundWriteFailure = abiOutboundWriteFailure abi,
        biAcceptFailures       = Nothing, -- TODO
        biSDUSize              = toSduSize (abiSDUSize abi)
      }



