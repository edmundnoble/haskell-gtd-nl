{-# LANGUAGE FlexibleContexts #-}

module GTD.Haskell.Cpphs where

import Control.Exception.Safe (tryAny)
import Control.Monad.Cont (MonadIO (..))
import Control.Monad.Except (MonadError (throwError))
import Language.Preprocessor.Cpphs (defaultCpphsOptions, runCpphs)
import Text.Printf (printf)

haskellApplyCppHs :: (MonadIO m, MonadError String m) => FilePath -> String -> m String
haskellApplyCppHs srcP srcC = do
  -- FIXME: `runCpphs` uses an `error` call internally on `#error` C preprocessor directive,
  -- and I could not make `tryAny` catch it for whatever reason.
  -- so, the `cpphs` library is forked and the `#error` handler is commented out. We don't need to fail on `#error`s anyway.
  r <- liftIO $ tryAny (runCpphs defaultCpphsOptions srcP srcC)
  case r of
    Left e -> throwError $ printf "failed to apply cpphs to %s: %s" srcP (show e)
    Right c -> return c
