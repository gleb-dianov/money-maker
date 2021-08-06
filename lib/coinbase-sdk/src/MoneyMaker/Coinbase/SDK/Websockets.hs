{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DeriveAnyClass #-}

module MoneyMaker.Coinbase.SDK.Websockets
  ( app

  , CoinbaseMessage(..)
  , TickerPriceData(..)

  , SubscribeMessage(..)
  , TradingPair(..)
  , Currency(..)
  , Channel(..)
  )
  where

import Protolude

import qualified Data.Aeson as Aeson
import qualified Data.Text  as Txt
import Data.Aeson ((.=), (.:))
-- import qualified Network.Socket         as Socket
import qualified Network.WebSockets     as WS
import qualified Control.Monad.Fail as Fail

app :: (TickerPriceData -> IO ()) -> WS.ClientApp ()
app writeNewPriceDataToQueue conn = do
  putStrLn @Text "Connected to Coinbase Websockets!"

  -- send subscribe message to tell coinbase what messages to send back
  WS.sendTextData conn $ Aeson.encode subscribeMessage

  void $ forever $ do
    msg <- WS.receiveData conn
    liftIO $ case Aeson.decode @CoinbaseMessage msg of
      Nothing ->
        putStrLn $ "Couldn't decode message: " <> msg

      Just message ->
        case message of
          UnknownMessage unknownMessage ->
            putStrLn $ "Unknown message: " <> unknownMessage
          Ticker newPriceData ->
            writeNewPriceDataToQueue newPriceData

  WS.sendClose conn ("Bye!" :: Text)

data CoinbaseMessage
  = UnknownMessage LByteString
  | Ticker TickerPriceData
  deriving stock (Eq, Show)

data TickerPriceData
  = TickerPriceData
      { productId :: TradingPair
      , price :: Text -- TODO: change to a better type for price data
      }
  deriving stock (Eq, Show)

instance Aeson.FromJSON CoinbaseMessage where
  parseJSON value
    = ($ value) $ Aeson.withObject "CoinbaseMessage"
    $ \object -> (object .: "type") >>= \case
        ("ticker" :: Text) ->
          Ticker <$> Aeson.parseJSON (Aeson.Object object)
        _ ->
          pure $ UnknownMessage $ Aeson.encode value

instance Aeson.FromJSON TickerPriceData where
  parseJSON
    = Aeson.withObject "TickerPriceData" $ \object -> do
        productId <- object .: "product_id"
        price     <- object .: "price"
        pure TickerPriceData{..}

subscribeMessage :: SubscribeMessage
subscribeMessage
  = SubscribeMessage
      { productIds = [TradingPair BTC USD]
      , channels = [TickerChannel []]
      }

data SubscribeMessage
  = SubscribeMessage
      { productIds :: [TradingPair]
      , channels   :: [Channel]
      }

instance Aeson.ToJSON SubscribeMessage where
  toJSON SubscribeMessage{..} = Aeson.object
    [ "product_ids" .= productIds
    , "channels" .= channels
    , "type" .= ("subscribe" :: Text)
    ]

data TradingPair
  = TradingPair
      { baseCurrency :: Currency
      , quoteCurrency :: Currency
      }
  deriving stock (Eq, Show)

instance Aeson.ToJSON TradingPair where
  toJSON TradingPair{..}
    = Aeson.String $ show baseCurrency <> "-" <> show quoteCurrency

instance Aeson.FromJSON TradingPair where
  parseJSON = Aeson.withText "TradingPair" $ \text -> do
    let [baseCoin, quoteCoin] = Txt.splitOn "-" text
    case (readMaybe $ toS baseCoin, readMaybe $ toS quoteCoin) of
      (Just baseCurrency, Just quoteCurrency) ->
        pure TradingPair{..}
      _ ->
        Fail.fail $ "Invalid trading pair: " <> toS text

data Currency
  = ETH
  | EUR
  | USD
  | BTC
  deriving stock (Eq, Show, Read)

data Channel
  = Level2Channel [TradingPair]
  | HeartbeatChannel [TradingPair]
  | TickerChannel [TradingPair]

instance Aeson.ToJSON Channel where
  toJSON = \case
    Level2Channel pairs ->
      channelToJSON "level2" pairs
    HeartbeatChannel pairs ->
      channelToJSON "heartbeat" pairs
    TickerChannel pairs ->
      channelToJSON "ticker" pairs
    where
      channelToJSON (name :: Text) = \case
        [] ->
          Aeson.String name
        pairs ->
          Aeson.object
            [ "name" .= name
            , "product_ids" .= pairs
            ]