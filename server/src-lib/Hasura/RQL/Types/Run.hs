{-# LANGUAGE UndecidableInstances #-}

module Hasura.RQL.Types.Run
  ( RunT(..)
  , RunCtx(..)
  , peelRun
  ) where

import           Hasura.Prelude

import qualified Network.HTTP.Client.Manager as HTTP

import           Control.Monad.Trans.Control (MonadBaseControl)
import           Control.Monad.Unique

import qualified Hasura.Tracing              as Tracing

import           Hasura.Base.Error
import           Hasura.Metadata.Class
import           Hasura.RQL.Types
import           Hasura.Session


data RunCtx
  = RunCtx
  { _rcUserInfo        :: !UserInfo
  , _rcHttpMgr         :: !HTTP.Manager
  , _rcServerConfigCtx :: !ServerConfigCtx
  }

newtype RunT m a
  = RunT { unRunT :: ReaderT RunCtx (ExceptT QErr m) a }
  deriving ( Functor, Applicative, Monad
           , MonadError QErr
           , MonadReader RunCtx
           , MonadIO
           , MonadMetadataStorage
           , Tracing.MonadTrace
           )

instance (MonadIO m) => MonadUnique (RunT m) where
  newUnique = liftIO newUnique

instance (MonadMetadataStorage m) => MonadMetadataStorageQueryAPI (RunT m)

deriving instance (MonadIO m, MonadBase IO m) => MonadBase IO (RunT m)
deriving instance (MonadIO m, MonadBaseControl IO m) => MonadBaseControl IO (RunT m)

instance (Monad m) => UserInfoM (RunT m) where
  askUserInfo = asks _rcUserInfo

instance (Monad m) => HTTP.HasHttpManagerM (RunT m) where
  askHttpManager = asks _rcHttpMgr

instance (Monad m) => HasServerConfigCtx (RunT m) where
  askServerConfigCtx = asks _rcServerConfigCtx

instance (MonadResolveSource m) => MonadResolveSource (RunT m) where
  getSourceResolver = RunT . lift . lift $ getSourceResolver

peelRun
  :: RunCtx
  -> RunT m a
  -> ExceptT QErr m a
peelRun runCtx (RunT m) = runReaderT m runCtx
