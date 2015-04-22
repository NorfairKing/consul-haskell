{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Consul (
    createManagedSession
  , deleteKey
  , destroyManagedSession
  , getKey
  , getKeys
  , getSessionInfo
  , initializeConsulClient
  , listKeys
  , putKey
  , putKeyAcquireLock
  , putKeyReleaseLock
  , withManagedSession
  , withSession
  , Consistency(..)
  , ConsulClient(..)
  , Datacenter(..)
  , KeyValue(..)
  , KeyValuePut(..)
  , ManagedSession(..)
  , Session(..)
) where

import Control.Concurrent hiding (killThread)
import Control.Concurrent.Lifted (fork, killThread)
import Control.Concurrent.STM
import Control.Monad.IO.Class
import Control.Monad.Trans.Control
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Data.Traversable
import Data.Word
import qualified Network.Consul.Internal as I
import Network.Consul.Types
import Network.HTTP.Client (defaultManagerSettings, newManager, Manager)
import Network.Socket (PortNumber)


import Prelude hiding (mapM)

initializeConsulClient :: MonadIO m => Text -> PortNumber -> Maybe Manager -> m ConsulClient
initializeConsulClient hostname port man = do
  manager <- liftIO $ case man of
                        Just x -> return x
                        Nothing -> newManager defaultManagerSettings
  return $ ConsulClient manager hostname port


{- Key Value -}

getKey :: MonadIO m => ConsulClient -> Text -> Maybe Word64 -> Maybe Consistency -> Maybe Datacenter -> m (Maybe KeyValue)
getKey _client@ConsulClient{..} = I.getKey ccManager ccHostname ccPort

getKeys :: MonadIO m => ConsulClient -> Text -> Maybe Word64 -> Maybe Consistency -> Maybe Datacenter -> m [KeyValue]
getKeys _client@ConsulClient{..} = I.getKeys ccManager ccHostname ccPort

listKeys :: MonadIO m => ConsulClient -> Text -> Maybe Word64 -> Maybe Consistency -> Maybe Datacenter -> m [Text]
listKeys _client@ConsulClient{..} = I.listKeys ccManager ccHostname ccPort

putKey :: MonadIO m => ConsulClient -> KeyValuePut -> Maybe Datacenter -> m Bool
putKey _client@ConsulClient{..} = I.putKey ccManager ccHostname ccPort

putKeyAcquireLock :: MonadIO m => ConsulClient -> KeyValuePut -> Session -> Maybe Datacenter -> m Bool
putKeyAcquireLock _client@ConsulClient{..} = I.putKeyAcquireLock ccManager ccHostname ccPort

putKeyReleaseLock :: MonadIO m => ConsulClient -> KeyValuePut -> Session -> Maybe Datacenter -> m Bool
putKeyReleaseLock _client@ConsulClient{..} = I.putKeyReleaseLock ccManager ccHostname ccPort

deleteKey :: MonadIO m => ConsulClient -> Text -> Bool -> Maybe Datacenter -> m ()
deleteKey _client@ConsulClient{..} key = I.deleteKey ccManager ccHostname ccPort key

{- Agent -}

{- Session -}
getSessionInfo :: MonadIO m => ConsulClient -> Text -> Maybe Datacenter -> m (Maybe [SessionInfo])
getSessionInfo _client@ConsulClient{..} = I.getSessionInfo ccManager ccHostname ccPort

withSession :: forall a m. (MonadIO m,MonadBaseControl IO m) => ConsulClient -> Session -> m a -> m a -> m a
withSession client session action lostAction = do
  var <- liftIO $ newEmptyTMVarIO
  tidVar <- liftIO $ newEmptyTMVarIO
  stid <- fork $ runThread var tidVar
  tid <- fork $ action >>= \ x -> liftIO $ atomically $ putTMVar var x
  liftIO $ atomically $ putTMVar tidVar tid
  ret <- liftIO $ atomically $ takeTMVar var
  killThread stid
  return ret
  where
    runThread :: TMVar a -> TMVar ThreadId -> m ()
    runThread var threadVar = do
      liftIO $ threadDelay (10 * 1000000)
      x <- getSessionInfo client (sId session) Nothing
      case x of
        Just [] -> cancel var threadVar
        Nothing -> cancel var threadVar
        Just _ -> runThread var threadVar

    cancel :: TMVar a -> TMVar ThreadId -> m ()
    cancel resultVar tidVar = do
      tid <- liftIO $ atomically $ readTMVar tidVar
      killThread tid
      empty <- liftIO $ atomically $ isEmptyTMVar resultVar
      if not empty then do
        result <- lostAction
        liftIO $ atomically $ putTMVar resultVar result
        return ()
        else return ()
        

{- Helper Functions -}

{- ManagedSession is a session with an associated TTL healthcheck so the session will be terminated if the client dies. The healthcheck will be automatically updated. -}
data ManagedSession = ManagedSession{
  msSession :: Session,
  msThreadId :: ThreadId
}

withManagedSession :: MonadIO m => ConsulClient -> Text -> (Session -> m ()) -> m () -> m ()
withManagedSession client ttl action lostAction = do
  x <- createManagedSession client Nothing ttl
  case x of
    Just s -> action (msSession s) >> destroyManagedSession client s
    Nothing -> lostAction >> return ()

createManagedSession :: MonadIO m => ConsulClient -> Maybe Text -> Text -> m (Maybe ManagedSession)
createManagedSession _client@ConsulClient{..} name ttl = do
  let r = SessionRequest Nothing name Nothing [] (Just Release) (Just ttl)
  s <- I.createSession ccManager ccHostname ccPort r Nothing
  mapM f s
  where
    f x = do
      tid <- liftIO $ forkIO $ runThread x
      return $ ManagedSession x tid
    
    saneTtl = let Right (x,_) = TR.decimal $ T.filter (/= 's') ttl in x

    runThread :: Session -> IO ()
    runThread s = do
      threadDelay $ (saneTtl - (saneTtl - 10)) * 1000000
      x <- I.renewSession ccManager ccHostname ccPort s Nothing
      case x of
        True -> runThread s
        False -> return ()

destroyManagedSession :: MonadIO m => ConsulClient -> ManagedSession -> m ()
destroyManagedSession _client@ConsulClient{..} (ManagedSession session tid) = do
  liftIO $ killThread tid
  I.destroySession ccManager ccHostname ccPort session Nothing
