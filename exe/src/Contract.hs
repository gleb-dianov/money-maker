{-# LANGUAGE DeriveAnyClass #-}

module Contract
  ( ContractualPriceData
  , toContractualPriceData
  )
  where

import qualified MoneyMaker.Coinbase.SDK.Websockets as Coinbase

import Protolude

import qualified Data.Aeson as Aeson

-- I think using "Contractual" prefix can help identify which types have to have
-- a certain encoding to not break the contract with the prediction mechanism
data ContractualPriceData
  = ContractualPriceData
      { productId :: Coinbase.TradingPair
      , price :: Text -- TODO: change to a better type for price data
      }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.ToJSON)

toContractualPriceData :: Coinbase.TickerPriceData -> ContractualPriceData
toContractualPriceData Coinbase.TickerPriceData{..}
  = ContractualPriceData{..}