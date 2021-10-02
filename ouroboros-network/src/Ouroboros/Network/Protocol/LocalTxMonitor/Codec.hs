{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

module Ouroboros.Network.Protocol.LocalTxMonitor.Codec (
    codecLocalTxMonitor
  , codecLocalTxMonitorId
  ) where

import           Control.Monad.Class.MonadST

import           Data.ByteString.Lazy (ByteString)
import qualified Codec.CBOR.Encoding as CBOR
import qualified Codec.CBOR.Decoding as CBOR
import qualified Codec.CBOR.Read     as CBOR
import           Text.Printf

import           Ouroboros.Network.Codec
import           Ouroboros.Network.Protocol.LocalTxMonitor.Type

codecLocalTxMonitor
  :: forall txid tx slot m ptcl. ( MonadST m, ptcl ~ LocalTxMonitor txid tx slot )
  => (txid -> CBOR.Encoding)
  -> (forall s. CBOR.Decoder s txid)
  -> (tx -> CBOR.Encoding)
  -> (forall s. CBOR.Decoder s tx)
  -> (slot -> CBOR.Encoding)
  -> (forall s. CBOR.Decoder s slot)
  -> Codec (LocalTxMonitor txid tx slot) CBOR.DeserialiseFailure m ByteString
codecLocalTxMonitor encodeTxId decodeTxId
                    encodeTx   decodeTx
                    encodeSlot decodeSlot =
    mkCodecCborLazyBS encode decode
  where
    encode
      :: forall (pr  :: PeerRole)
                (st  :: ptcl)
                (st' :: ptcl). ()
      => PeerHasAgency pr st
      -> Message ptcl st st'
      -> CBOR.Encoding
    encode (ClientAgency TokIdle) = \case
      MsgDone ->
        CBOR.encodeListLen 1 <> CBOR.encodeWord 0
      MsgAcquire ->
        CBOR.encodeListLen 1 <> CBOR.encodeWord 1

    encode (ClientAgency TokAcquired) = \case
      MsgReAcquire ->
        CBOR.encodeListLen 1 <> CBOR.encodeWord 1
      MsgRelease ->
        CBOR.encodeListLen 1 <> CBOR.encodeWord 3
      MsgNextTx ->
        CBOR.encodeListLen 1 <> CBOR.encodeWord 5
      MsgHasTx txid ->
        CBOR.encodeListLen 2 <> CBOR.encodeWord 7 <> encodeTxId txid

    encode (ServerAgency TokAcquiring) = \case
      MsgAcquired slot ->
        CBOR.encodeListLen 2 <> CBOR.encodeWord 2 <> encodeSlot slot

    encode (ServerAgency (TokBusy TokBusyNext)) = \case
      MsgReplyNextTx Nothing ->
        CBOR.encodeListLen 1 <> CBOR.encodeWord 6
      MsgReplyNextTx (Just tx) ->
        CBOR.encodeListLen 2 <> CBOR.encodeWord 6 <> encodeTx tx

    encode (ServerAgency (TokBusy TokBusyHas)) = \case
      MsgReplyHasTx has ->
        CBOR.encodeListLen 2 <> CBOR.encodeWord 8 <> CBOR.encodeBool has

    decode
      :: forall s
                (pr :: PeerRole)
                (st :: ptcl). ()
      => PeerHasAgency pr st
      -> CBOR.Decoder s (SomeMessage st)
    decode stok = do
      len <- CBOR.decodeListLen
      key <- CBOR.decodeWord
      case (stok, len, key) of
        (ClientAgency TokIdle, 1, 0) ->
          return (SomeMessage MsgDone)
        (ClientAgency TokIdle, 1, 1) ->
          return (SomeMessage MsgAcquire)

        (ClientAgency TokAcquired, 1, 1) ->
          return (SomeMessage MsgReAcquire)
        (ClientAgency TokAcquired, 1, 3) ->
          return (SomeMessage MsgRelease)
        (ClientAgency TokAcquired, 1, 5) ->
          return (SomeMessage MsgNextTx)
        (ClientAgency TokAcquired, 2, 7) -> do
          txid <- decodeTxId
          return (SomeMessage (MsgHasTx txid))

        (ServerAgency TokAcquiring, 2, 2) -> do
          slot <- decodeSlot
          return (SomeMessage (MsgAcquired slot))

        (ServerAgency (TokBusy TokBusyNext), 1, 6) ->
          return (SomeMessage (MsgReplyNextTx Nothing))
        (ServerAgency (TokBusy TokBusyNext), 2, 6) -> do
          tx <- decodeTx
          return (SomeMessage (MsgReplyNextTx (Just tx)))

        (ServerAgency (TokBusy TokBusyHas), 2, 8) -> do
          has <- CBOR.decodeBool
          return (SomeMessage (MsgReplyHasTx has))

        (ClientAgency TokIdle, _, _) ->
          fail (printf "codecLocalTxMonitor (%s) unexpected key (%d, %d)" (show stok) key len)
        (ClientAgency TokAcquired, _, _) ->
          fail (printf "codecLocalTxMonitor (%s) unexpected key (%d, %d)" (show stok) key len)
        (ServerAgency TokAcquiring, _, _) ->
          fail (printf "codecLocalTxMonitor (%s) unexpected key (%d, %d)" (show stok) key len)
        (ServerAgency (TokBusy _), _, _) ->
          fail (printf "codecLocalTxMonitor (%s) unexpected key (%d, %d)" (show stok) key len)

-- | An identity 'Codec' for the 'LocalTxMonitor' protocol. It does not do
-- any serialisation. It keeps the typed messages, wrapped in 'AnyMessage'.
--
codecLocalTxMonitorId
  :: forall txid tx slot m ptcl. ( Monad m, ptcl ~ LocalTxMonitor txid tx slot )
  => Codec ptcl CodecFailure m (AnyMessage ptcl)
codecLocalTxMonitorId =
    Codec encode decode
  where
    encode
      :: forall (pr :: PeerRole) st st'. ()
      => PeerHasAgency pr st
      -> Message ptcl st st'
      -> AnyMessage ptcl
    encode _ =
      AnyMessage

    decode
      :: forall (pr :: PeerRole) (st :: ptcl). ()
      => PeerHasAgency pr st
      -> m (DecodeStep (AnyMessage ptcl) CodecFailure m (SomeMessage st))
    decode stok =
      let res :: Message ptcl st st' -> m (DecodeStep bytes failure m (SomeMessage st))
          res msg = return (DecodeDone (SomeMessage msg) Nothing)
       in return $ DecodePartial $ \bytes -> case (stok, bytes) of
        (ClientAgency TokIdle,     Just (AnyMessage msg@MsgAcquire{}))   -> res msg
        (ClientAgency TokIdle,     Just (AnyMessage msg@MsgDone{}))      -> res msg
        (ClientAgency TokAcquired, Just (AnyMessage msg@MsgReAcquire{})) -> res msg
        (ClientAgency TokAcquired, Just (AnyMessage msg@MsgNextTx{}))    -> res msg
        (ClientAgency TokAcquired, Just (AnyMessage msg@MsgHasTx{}))     -> res msg
        (ClientAgency TokAcquired, Just (AnyMessage msg@MsgRelease{}))   -> res msg

        (ServerAgency TokAcquiring,          Just (AnyMessage msg@MsgAcquired{}))    -> res msg
        (ServerAgency (TokBusy TokBusyNext), Just (AnyMessage msg@MsgReplyNextTx{})) -> res msg
        (ServerAgency (TokBusy TokBusyHas),  Just (AnyMessage msg@MsgReplyHasTx{}))  -> res msg

        (_, Nothing) ->
          return (DecodeFail CodecFailureOutOfInput)
        (_, _) ->
          return (DecodeFail (CodecFailure "codecLocalTxMonitorId: no matching message"))