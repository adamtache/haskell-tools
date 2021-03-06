{-# LANGUAGE DeriveGeneric, OverloadedStrings, StandaloneDeriving, TemplateHaskell, TypeFamilies, ViewPatterns #-}

module CoinMetrics.Ripple
  ( Ripple(..)
  , RippleLedger(..)
  , RippleTransaction(..)
  ) where

import Control.Monad
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as J
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.HashMap.Strict as HM
import Data.Int
import Data.Proxy
import Data.Scientific
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Time.Clock.POSIX as Time
import qualified Data.Time.ISO8601 as Time
import qualified Data.Vector as V
import qualified Network.HTTP.Client as H
import Text.ParserCombinators.ReadP

import CoinMetrics.BlockChain
import CoinMetrics.Schema.Util
-- import CoinMetrics.Schema.Flatten
import CoinMetrics.Util
import Hanalytics.Schema

-- | Ripple connector.
data Ripple = Ripple
  { ripple_httpManager :: !H.Manager
  , ripple_httpRequest :: !H.Request
  }

rippleRequest :: J.FromJSON r => Ripple -> T.Text -> [(B.ByteString, Maybe B.ByteString)] -> IO r
rippleRequest Ripple
  { ripple_httpManager = httpManager
  , ripple_httpRequest = httpRequest
  } path params = tryWithRepeat $ do
  body <- H.responseBody <$> H.httpLbs (H.setQueryString params httpRequest
    { H.path = T.encodeUtf8 path
    }) httpManager
  case J.eitherDecode body of
    Right decodedBody -> return decodedBody
    Left err -> do
      putStrLn $ "wrong ripple response for " <> T.unpack path <> ": " <> T.unpack (T.decodeUtf8 $ BL.toStrict $ BL.take 256 body)
      fail err

-- https://ripple.com/build/data-api-v2/#ledger-objects

data RippleLedger = RippleLedger
  { rl_index :: {-# UNPACK #-} !Int64
  , rl_hash :: {-# UNPACK #-} !HexString
  , rl_totalCoins :: {-# UNPACK #-} !Scientific
  , rl_closeTime :: {-# UNPACK #-} !Int64
  , rl_transactions :: !(V.Vector (Maybe RippleTransaction))
  }

instance IsBlock RippleLedger where
  getBlockHeight = rl_index
  getBlockTimestamp = Time.posixSecondsToUTCTime . fromIntegral . rl_closeTime

newtype RippleLedgerWrapper = RippleLedgerWrapper
  { unwrapRippleLedger :: RippleLedger
  }

instance J.FromJSON RippleLedgerWrapper where
  parseJSON = J.withObject "ripple ledger" $ \fields -> fmap RippleLedgerWrapper $ RippleLedger
    <$> (fields J..: "ledger_index")
    <*> (fields J..: "ledger_hash")
    <*> (decodeAmount =<< fields J..: "total_coins")
    <*> (fields J..: "close_time")
    <*> (V.map (unwrapRippleTransaction <$>) <$> fields J..: "transactions")

data RippleTransaction = RippleTransaction
  { rt_hash :: {-# UNPACK #-} !HexString
  , rt_date :: {-# UNPACK #-} !Int64
  , rt_account :: !T.Text
  , rt_fee :: {-# UNPACK #-} !Scientific
  , rt_type :: !T.Text
  , rt_amount :: !(Maybe Scientific)
  , rt_currency :: !(Maybe T.Text)
  , rt_issuer :: !(Maybe T.Text)
  , rt_destination :: !(Maybe T.Text)
  , rt_result :: !T.Text
  }

newtype RippleTransactionWrapper = RippleTransactionWrapper
  { unwrapRippleTransaction :: RippleTransaction
  }

instance J.FromJSON RippleTransactionWrapper where
  parseJSON = J.withObject "ripple transaction" $ \fields -> do
    tx <- fields J..: "tx"
    maybeAmountValue <- tx J..:? "Amount"
    (maybeAmount, maybeCurrency, maybeIssuer) <-
      case maybeAmountValue of
        Just amountValue -> case amountValue of
          J.String amountStr -> do
            amount <- decodeAmount amountStr
            return (Just amount, Nothing, Nothing)
          J.Object amountObject -> do
            amount <- decodeAmount =<< amountObject J..: "value"
            currency <- amountObject J..: "currency"
            issuer <- amountObject J..: "issuer"
            return (Just amount, Just currency, Just issuer)
          _ -> fail "wrong amount"
        Nothing -> return (Nothing, Nothing, Nothing)
    meta <- fields J..: "meta"
    fmap RippleTransactionWrapper $ RippleTransaction
      <$> (fields J..: "hash")
      <*> (decodeDate =<< fields J..: "date")
      <*> (tx J..: "Account")
      <*> (decodeAmount =<< tx J..: "Fee")
      <*> (tx J..: "TransactionType")
      <*> return maybeAmount
      <*> return maybeCurrency
      <*> return maybeIssuer
      <*> (tx J..:? "Destination")
      <*> (meta J..: "TransactionResult")

decodeAmount :: T.Text -> J.Parser Scientific
decodeAmount (T.unpack -> t) = case readP_to_S scientificP t of
  [(value, "")] -> return value
  _ -> fail $ "wrong amount: " <> t

decodeDate :: T.Text -> J.Parser Int64
decodeDate (T.unpack -> t) = case Time.parseISO8601 t of
  Just date -> return $ floor $ Time.utcTimeToPOSIXSeconds date
  Nothing -> fail $ "wrong date: " <> t


genSchemaInstances [''RippleLedger, ''RippleTransaction]
-- doesn't work because of Vector (Maybe RippleTransaction)
-- genFlattenedTypes "index" [| rl_index |] [("ledger", ''RippleLedger), ("transaction", ''RippleTransaction)]

instance BlockChain Ripple where
  type Block Ripple = RippleLedger

  getBlockChainInfo _ = BlockChainInfo
    { bci_init = \BlockChainParams
      { bcp_httpManager = httpManager
      , bcp_httpRequest = httpRequest
      } -> return Ripple
        { ripple_httpManager = httpManager
        , ripple_httpRequest = httpRequest
        }
    , bci_defaultApiUrl = "https://data.ripple.com/"
    , bci_defaultBeginBlock = 32570 -- genesis ledger
    , bci_defaultEndBlock = 0 -- history data, no rewrites
    , bci_schemas = standardBlockChainSchemas
      (schemaOf (Proxy :: Proxy RippleLedger))
      [ schemaOf (Proxy :: Proxy RippleTransaction)
      ]
      "CREATE TABLE \"ripple\" OF \"RippleLedger\" (PRIMARY KEY (\"index\"));"
    -- , bci_flattenSuffixes = ["ledgers", "transactions"]
    -- , bci_flattenPack = let
    --  f (ledgers, transactions) =
    --    [ SomeBlocks (ledgers :: [RippleLedger_flattened])
    --    , SomeBlocks (transactions :: [RippleTransaction_flattened])
    --    ]
    --  in f . mconcat . map flatten
    }

  getCurrentBlockHeight ripple = either fail return
    . J.parseEither ((J..: "ledger_index") <=< (J..: "ledger"))
    =<< rippleRequest ripple "/v2/ledgers" []

  getBlockByHeight ripple blockHeight = do
    eitherLedger <- J.parseEither (J..: "ledger")
      <$> rippleRequest ripple ("/v2/ledgers/" <> T.pack (show blockHeight))
        [ ("transactions", Just "true")
        , ("expand", Just "true")
        ]
    case eitherLedger of
      Right ledger -> return ledger
      Left _ -> do
        -- fallback to retrieving transactions individually
        preLedger <- either fail return
          . J.parseEither (J..: "ledger")
          =<< rippleRequest ripple ("/v2/ledgers/" <> T.pack (show blockHeight))
            [ ("transactions", Just "true")
            ]
        transactionsHashes <- either fail return $ J.parseEither (J..: "transactions") preLedger
        transactions <- forM transactionsHashes $ \transactionHash ->
          either (const J.Null) J.Object . J.parseEither (J..: "transaction")
            <$> rippleRequest ripple ("/v2/transactions/" <> transactionHash) []
        either fail (return . unwrapRippleLedger) $ J.parseEither J.parseJSON $ J.Object $ HM.insert "transactions" (J.Array transactions) preLedger

  blockHeightFieldName _ = "index"
