{-# LANGUAGE DeriveGeneric, LambdaCase, OverloadedLists, OverloadedStrings, TemplateHaskell, TypeFamilies, ViewPatterns #-}

module CoinMetrics.Tron
	( Tron(..)
	, TronBlock(..)
	, TronTransaction(..)
	, TronContract(..)
	, TronVote(..)
	) where

import Control.Monad
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as J
import GHC.Generics(Generic)
import Data.Int
import Data.Maybe
import Data.Proxy
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Network.HTTP.Client as H

import CoinMetrics.BlockChain
import CoinMetrics.Schema.Flatten
import CoinMetrics.Schema.Util
import CoinMetrics.Util
import Hanalytics.Schema

data Tron = Tron
	{ tron_httpManager :: !H.Manager
	, tron_httpRequest :: !H.Request
	}

data TronBlock = TronBlock
	{ tb_hash :: {-# UNPACK #-} !HexString
	, tb_timestamp :: {-# UNPACK #-} !Int64
	, tb_number :: {-# UNPACK #-} !Int64
	, tb_transactions :: !(V.Vector TronTransaction)
	} deriving Generic

newtype TronBlockWrapper = TronBlockWrapper
	{ unwrapTronBlock :: TronBlock
	}

instance J.FromJSON TronBlockWrapper where
	parseJSON = J.withObject "tron block" $ \fields -> do
		headerData <- (J..: "raw_data") =<< fields J..: "block_header"
		fmap TronBlockWrapper $ TronBlock
			<$> (fields J..: "blockID")
			<*> (headerData J..: "timestamp")
			<*> (headerData J..: "number")
			<*> (V.map unwrapTronTransaction . fromMaybe mempty <$> fields J..:? "transactions")

data TronTransaction = TronTransaction
	{ tt_hash :: {-# UNPACK #-} !HexString
	, tt_ref_block_bytes :: {-# UNPACK #-} !HexString
	, tt_ref_block_num :: !(Maybe Int64)
	, tt_ref_block_hash :: {-# UNPACK #-} !HexString
	, tt_expiration :: {-# UNPACK #-} !Int64
	, tt_timestamp :: !(Maybe Int64)
	, tt_contracts :: !(V.Vector TronContract)
	} deriving Generic

newtype TronTransactionWrapper = TronTransactionWrapper
	{ unwrapTronTransaction :: TronTransaction
	}

instance J.FromJSON TronTransactionWrapper where
	parseJSON = J.withObject "tron transaction" $ \fields -> do
		rawData <- fields J..: "raw_data"
		fmap TronTransactionWrapper $ TronTransaction
			<$> (fields J..: "txID")
			<*> (rawData J..: "ref_block_bytes")
			<*> (rawData J..:? "ref_block_num")
			<*> (rawData J..: "ref_block_hash")
			<*> (rawData J..: "expiration")
			<*> (rawData J..:? "timestamp")
			<*> (V.map unwrapTronContract <$> rawData J..: "contract")

{-
Fields noted for:
AccountUpdateContract
FreezeBalanceContract
ParticipateAssetIssueContract
TransferAssetContract
TransferContract
UnfreezeBalanceContract
VoteWitnessContract
WithdrawBalanceContract
-}
data TronContract = TronContract
	{ tc_type :: !T.Text
	, tc_amount :: !(Maybe Int64)
	, tc_account_name :: !(Maybe HexString)
	, tc_asset_name :: !(Maybe HexString)
	, tc_owner_address :: !(Maybe HexString)
	, tc_to_address :: !(Maybe HexString)
	, tc_frozen_duration :: !(Maybe Int64)
	, tc_frozen_balance :: !(Maybe Int64)
	, tc_votes :: !(V.Vector TronVote)
	} deriving Generic

newtype TronContractWrapper = TronContractWrapper
	{ unwrapTronContract :: TronContract
	}

instance J.FromJSON TronContractWrapper where
	parseJSON = J.withObject "tron contract" $ \fields -> do
		value <- (J..: "value") =<< fields J..: "parameter"
		fmap TronContractWrapper $ TronContract
			<$> (fields J..: "type")
			<*> (value J..:? "amount")
			<*> (value J..:? "account_name")
			<*> (value J..:? "asset_name")
			<*> (value J..:? "owner_address")
			<*> (value J..:? "to_address")
			<*> (value J..:? "frozen_duration")
			<*> (value J..:? "frozen_balance")
			<*> (V.map unwrapTronVote . fromMaybe mempty <$> value J..:? "votes")

data TronVote = TronVote
	{ tv_address :: {-# UNPACK #-} !HexString
	, tv_count :: {-# UNPACK #-} !Int64
	} deriving Generic

newtype TronVoteWrapper = TronVoteWrapper
	{ unwrapTronVote :: TronVote
	}

instance J.FromJSON TronVoteWrapper where
	parseJSON = J.withObject "tron vote" $ \fields -> fmap TronVoteWrapper $ TronVote
		<$> (fields J..: "vote_address")
		<*> (fields J..: "vote_count")

genSchemaInstances [''TronBlock, ''TronTransaction, ''TronContract, ''TronVote]
genFlattenedTypes "number" [| tb_number |] [("block", ''TronBlock), ("transaction", ''TronTransaction), ("contract", ''TronContract), ("vote", ''TronVote)]

instance BlockChain Tron where
	type Block Tron = TronBlock

	getBlockChainInfo _ = BlockChainInfo
		{ bci_init = \BlockChainParams
			{ bcp_httpManager = httpManager
			, bcp_httpRequest = httpRequest
			} -> return Tron
			{ tron_httpManager = httpManager
			, tron_httpRequest = httpRequest
			}
		, bci_defaultApiUrl = "http://127.0.0.1:8091/"
		, bci_defaultBeginBlock = 0
		, bci_defaultEndBlock = 0 -- no need in gap with solidity node
		, bci_schemas = standardBlockChainSchemas
			(schemaOf (Proxy :: Proxy TronBlock))
			[ schemaOf (Proxy :: Proxy TronVote)
			, schemaOf (Proxy :: Proxy TronContract)
			, schemaOf (Proxy :: Proxy TronTransaction)
			]
			"CREATE TABLE \"tron\" OF \"TronBlock\" (PRIMARY KEY (\"number\"));"
		, bci_flattenSuffixes = ["blocks", "transactions", "logs", "actions", "uncles"]
		, bci_flattenPack = let
			f (blocks, (transactions, (contracts, votes))) =
				[ SomeBlocks (blocks :: [TronBlock_flattened])
				, SomeBlocks (transactions :: [TronTransaction_flattened])
				, SomeBlocks (contracts :: [TronContract_flattened])
				, SomeBlocks (votes :: [TronVote_flattened])
				]
			in f . mconcat . map flatten
		}

	getCurrentBlockHeight Tron
		{ tron_httpManager = httpManager
		, tron_httpRequest = httpRequest
		} = do
		response <- tryWithRepeat $ H.httpLbs httpRequest
			{ H.path = "/walletsolidity/getnowblock"
			} httpManager
		either fail return $ J.parseEither ((J..: "number") <=< (J..: "raw_data") <=< (J..: "block_header")) =<< J.eitherDecode' (H.responseBody response)

	getBlockByHeight Tron
		{ tron_httpManager = httpManager
		, tron_httpRequest = httpRequest
		} blockHeight = do
		print blockHeight
		response <- tryWithRepeat $ H.httpLbs httpRequest
			{ H.path = "/walletsolidity/getblockbynum"
			, H.requestBody = H.RequestBodyLBS $ J.encode $ J.Object
				[ ("num", J.Number $ fromIntegral blockHeight)
				]
			, H.method = "POST"
			} httpManager
		either fail (return . unwrapTronBlock) $ J.eitherDecode' $ H.responseBody response

	blockHeightFieldName _ = "number"
