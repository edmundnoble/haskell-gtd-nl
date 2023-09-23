{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module GTD.Resolution.Caching.Utils where

import Control.Exception (try)
import Control.Monad.Logger (MonadLoggerIO)
import Control.Monad.Reader (MonadIO (..), MonadReader)
import Data.Binary (Binary, decodeFileOrFail)
import GTD.Configuration (GTDConfiguration)
import GTD.Utils (logDebugNSS)
import Text.Printf (printf)

pathAsFile :: FilePath -> FilePath
pathAsFile = fmap $ \s -> if s == '/' then '_' else s

binaryGet :: FilePath -> (MonadLoggerIO m, MonadReader GTDConfiguration m, Binary a) => m (Maybe a)
binaryGet p =
  liftIO (try $ decodeFileOrFail p) >>= \case
    Left (e :: IOError) -> logDebugNSS "binary get" (printf "%s failed: %s" p (show e)) >> return Nothing
    Right ew -> case ew of
      Left (_, e) -> logDebugNSS "binary get" (printf "%s: reading succeeded, yet decodeFileOrFail failed: %s" p $ show e) >> return Nothing
      Right w -> logDebugNSS "binary get" (printf "%s succeded" p) >> return (Just w)
