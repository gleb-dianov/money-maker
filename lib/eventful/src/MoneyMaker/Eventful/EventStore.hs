{-# LANGUAGE AllowAmbiguousTypes #-}

module MoneyMaker.Eventful.EventStore
  ( getAggregate
  , applyCommand
  , MonadEventStore(..)
  , CouldntDecodeEventError(..)

  , StorableEvent(..)
  , InMemoryEventStoreT(..)
  , runInMemoryEventStoreTWithoutErrors
  )
  where

import MoneyMaker.Error
import MoneyMaker.Eventful.Command
import MoneyMaker.Eventful.Event

import Protolude

import qualified Data.Aeson as Aeson
import qualified Data.UUID  as UUID
import qualified Prelude

getAggregate
  :: forall event errors m
   . ( Eventful event
     , MonadEventStore m
     , MonadUltraError m
     , NoEventsFoundError `Elem` errors
     , EventError event `Elem` errors
     , CouldntDecodeEventError  `Elem` errors
     )
  => Id (EventName event)
  -> m errors (EventAggregate event)
getAggregate = getAggregateWithProxy $ Proxy @event

applyCommand
  :: forall event errors command m
   . ( Command command event
     , MonadEventStore m
     , EventError event `Elem` errors
     , CouldntDecodeEventError `Elem` errors
     , CommandError command `Elem` errors
     , EventError event `Elem` errors
     , Eventful event
     )
  => Id (EventName event)
  -> command
  -> m errors (EventAggregate event)
applyCommand = applyCommandWithProxy $ Proxy @event

data CouldntDecodeEventError
  = CouldntDecodeEventError Prelude.String

class MonadUltraError m => MonadEventStore (m :: [Type] -> Type -> Type) where
  getAggregateWithProxy
    :: ( NoEventsFoundError `Elem` errors
       , EventError event `Elem` errors
       , CouldntDecodeEventError `Elem` errors
       , Eventful event
       )
    => Proxy event
    -> Id (EventName event)
    -> m errors (EventAggregate event)

  applyCommandWithProxy
    :: ( Command command event
       , EventError event `Elem` errors
       , CouldntDecodeEventError `Elem` errors
       , CommandError command `Elem` errors
       , EventError event `Elem` errors
       , Eventful event
       )
    => Proxy event
    -> Id (EventName event)
    -> command
    -> m errors (EventAggregate event)

data StorableEvent
  = StorableEvent
      { id      :: !UUID.UUID
      , payload :: !Aeson.Value -- ^ JSON encoded event
      }

-- | Non-persisted in-memory event store for testing
newtype InMemoryEventStoreT (m :: Type -> Type) (errors :: [Type]) (a :: Type)
  = InMemoryEventStoreT
      { runInMemoryEventStore :: StateT [StorableEvent] (UltraExceptT m errors) a }
  deriving newtype (Functor, Applicative, Monad, MonadState [StorableEvent])

runInMemoryEventStoreTWithoutErrors
  :: Monad m
  => [StorableEvent]
  -> InMemoryEventStoreT m '[] a
  -> m (a, [StorableEvent])
runInMemoryEventStoreTWithoutErrors initialEvents (InMemoryEventStoreT action)
  = runUltraExceptTWithoutErrors $ runStateT action initialEvents

instance Monad m => MonadUltraError (InMemoryEventStoreT m) where
  throwUltraError = InMemoryEventStoreT . lift . throwUltraError

  catchUltraErrorMethod
    :: forall error errors a
     . InMemoryEventStoreT m (error:errors) a
    -> (error -> InMemoryEventStoreT m errors a)
    -> InMemoryEventStoreT m errors a
  catchUltraErrorMethod (InMemoryEventStoreT action) handleError = do
    currentState <- get
    result :: Either (OneOf (error:errors)) (a, [StorableEvent]) <-
      InMemoryEventStoreT -- InMemoryEventStoreT m errors (Either (OneOf (error:errors)) (a, [StorableEvent]))
        $ lift -- StateT [StorableEvent] (UltraExceptT m errors) (Either (OneOf (error:errors)) (a, [StorableEvent]))
        $ liftToUltraExceptT -- UltraExceptT m errors (Either (OneOf (error:errors)) (a, [StorableEvent]))
        $ runUltraExceptT -- m (Either (OneOf (error:errors)) (a, [StorableEvent]))
        $ runStateT action currentState -- UltraExceptT m (error:errors) (a, [StorableEvent])

    case result of
      Right (val, _) ->
        InMemoryEventStoreT $ pure val

      Left err ->
        case getOneOf err of
          Right error -> handleError error
          Left otherErr ->
            InMemoryEventStoreT $ lift $ UltraExceptT $ ExceptT $ pure $ Left otherErr


instance Monad m => MonadEventStore (InMemoryEventStoreT m) where
  getAggregateWithProxy = getAggregateWithProxyInMemory
  applyCommandWithProxy = applyCommandWithProxyInMemory

getAggregateWithProxyInMemory
  :: ( NoEventsFoundError `Elem` errors
     , EventError event `Elem` errors
     , CouldntDecodeEventError  `Elem` errors
     , Eventful event
     , Monad m
     )
  => Proxy event
  -> Id (EventName event)
  -> InMemoryEventStoreT m errors (EventAggregate event)

getAggregateWithProxyInMemory (_ :: Proxy event) (Id uuid) = do
  allEvents <- get

  let relevantEvents
        = sequence
        $ Aeson.fromJSON . payload
            <$> filter ((== uuid) . id) allEvents

  case relevantEvents of
    Aeson.Error err ->
      throwUltraError $ CouldntDecodeEventError err
    Aeson.Success events ->
      computeCurrentState @event events


applyCommandWithProxyInMemory
  :: forall command event errors m
   . ( Command command event
     , CouldntDecodeEventError `Elem` errors
     , CommandError command `Elem` errors
     , EventError event `Elem` errors
     , Eventful event
     , Monad m
     )
  => Proxy event
  -> Id (EventName event)
  -> command
  -> InMemoryEventStoreT m errors (EventAggregate event)

applyCommandWithProxyInMemory eventProxy aggregateId command = do
  -- Get the current aggregate if it exists
  maybeAggregate :: Maybe (EventAggregate event) <-
    catchUltraError @NoEventsFoundError
      (Just <$> getAggregateWithProxyInMemory eventProxy aggregateId)
      (const $ pure Nothing)

  -- Use the command's handleCommand method to get what events should be added
  (headEvent :| tailEvents) <- handleCommand maybeAggregate command

  let allEvents = headEvent : tailEvents

  -- Get a non-maybe aggregate
  nextAggregate <-
    applyEvent maybeAggregate headEvent

  -- Apply the rest of the new events to the aggregate
  aggregate <-
    foldM -- :: (b -> a -> m b) -> b -> t a -> m b
      (\agg nextEvent -> applyEvent (Just agg) nextEvent)
      nextAggregate
      tailEvents

  -- Prepare to store the new events in the right format
  let newStorableEvents :: [StorableEvent]
        = StorableEvent (getId aggregateId) . Aeson.toJSON <$> allEvents

  -- Update the state with the new events and return the new aggregate
  state $ (aggregate,) . (<> newStorableEvents)
