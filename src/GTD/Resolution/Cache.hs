{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module GTD.Resolution.Cache where

import Control.Lens (over, view)
import Control.Monad.Except (MonadIO (..))
import Control.Monad.Logger (MonadLoggerIO, LogLevel (LevelDebug))
import Control.Monad.RWS (MonadReader (..), MonadState (..), asks, gets, modify)
import qualified Data.Binary as Binary (Binary, encodeFile)
import qualified Data.Cache.LRU as LRU
import qualified Data.Map as Map
import Data.Maybe (isJust)
import qualified GTD.Cabal.Types as Cabal (ModuleNameS, Package (..), PackageKey, PackageWithResolvedDependencies, dKey, key, pKey)
import GTD.Configuration (Args (..), GTDConfiguration (..))
import GTD.Haskell.Declaration (Declarations)
import GTD.Haskell.Lines (Lines)
import GTD.Haskell.Module (HsModule (..))
import qualified GTD.Haskell.Module as HsModule
import GTD.Resolution.Caching.Utils (binaryGet, pathAsFile)
import GTD.Resolution.State (Context, Package (..), cExports)
import qualified GTD.Resolution.State as Package
import GTD.Utils (logDebugNSS, removeIfExistsL)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeDirectoryRecursive)
import System.FilePath.Posix ((</>))
import Text.Printf (printf)
import Control.Monad (when)
import qualified Data.Aeson as JSON

exportsN :: String
exportsN = "exports.binary"

modulesN :: String
modulesN = "modules.binary"

path :: Cabal.Package a -> FilePath -> (MonadIO m, MonadReader GTDConfiguration m) => m FilePath
path cPkg f = do
  c <- asks _cache
  d <- __resolution'dir $ Cabal.key cPkg
  let r = pathAsFile $ Cabal._root cPkg
      p = Cabal.dKey . Cabal._designation $ cPkg
  return $ c </> d </> (r ++ ":" ++ p ++ ":" ++ f)

__pGet :: Cabal.Package b -> FilePath -> (MonadLoggerIO m, MonadReader GTDConfiguration m, Binary.Binary a) => m (Maybe a)
__pGet cPkg f = do
  p <- path cPkg f
  binaryGet p

pExists :: Cabal.Package a -> (MonadLoggerIO m, MonadReader GTDConfiguration m) => m Bool
pExists cPkg = do
  p <- path cPkg exportsN
  r <- liftIO $ doesFileExist p
  logDebugNSS "package cached exists" $ printf "%s, %s -> %s" (show $ Cabal.key cPkg) p (show r)
  return r

pGet :: Cabal.PackageWithResolvedDependencies -> (MonadLoggerIO m, MonadReader GTDConfiguration m) => m (Maybe Package)
pGet cPkg = do
  modulesJ <- __pGet cPkg modulesN
  exportsJ <- __pGet cPkg exportsN
  let p = Package cPkg <$> modulesJ <*> exportsJ
  logDebugNSS "package cached get" $ printf "%s -> %s (%s, %s)" (show $ Cabal.key cPkg) (show $ isJust p) (show $ isJust modulesJ) (show $ isJust exportsJ)
  return p

pStore ::
  Cabal.PackageWithResolvedDependencies ->
  Package ->
  (MonadLoggerIO m, MonadReader GTDConfiguration m) => m ()
pStore cPkg pkg = do
  ll <- asks $ _logLevel . _args
  modulesP <- path cPkg modulesN
  exportsP <- path cPkg exportsN
  liftIO $ Binary.encodeFile modulesP $ Package._modules pkg
  liftIO $ Binary.encodeFile exportsP $ Package._exports pkg
  liftIO $ when (ll == LevelDebug) $ do
    JSON.encodeFile (modulesP ++ ".json") (Package._modules pkg)
    JSON.encodeFile (exportsP ++ ".json") (Package._exports pkg)
  logDebugNSS "package cached put" $ printf "%s -> (%d, %d)" (show $ Cabal.key cPkg) (length $ Package._modules pkg) (length $ Package._exports pkg)

pRemove ::
  Cabal.Package a ->
  (MonadLoggerIO m, MonadReader GTDConfiguration m) => m ()
pRemove cPkg = do
  path cPkg modulesN >>= removeIfExistsL
  path cPkg exportsN >>= removeIfExistsL
  logDebugNSS "package cached remove" $ printf "%s" (show $ Cabal.key cPkg)

get ::
  Context ->
  Cabal.PackageWithResolvedDependencies ->
  (MonadLoggerIO m, MonadReader GTDConfiguration m) => m (Maybe Package, Context -> Context)
get c cPkg = do
  let k = Cabal.key cPkg
      (_, r) = LRU.lookup k (view cExports c)
      defM = over cExports (fst . LRU.lookup k)
  logDebugNSS "package cached get'" $ printf "%s -> %s" (show $ Cabal.key cPkg) (show $ isJust r)
  case r of
    Just es -> return (Just Package {_cabalPackage = cPkg, _modules = Map.empty, Package._exports = es}, defM)
    Nothing -> do
      eM <- __pGet cPkg exportsN
      return $ case eM of
        Nothing -> (Nothing, defM)
        Just e -> (Just Package {_cabalPackage = cPkg, _modules = Map.empty, Package._exports = e}, over cExports (LRU.insert k e))

setCacheMaxSize :: (MonadLoggerIO m, MonadState (LRU.LRU k v) m, Ord k) => Integer -> m ()
setCacheMaxSize n = do
  z <- gets LRU.maxSize
  case z of
    Just n0 | n0 >= n -> return ()
    _ -> do
      logDebugNSS "package cache" $ printf "setting size to %d" n
      modify $ \lru -> LRU.fromList (Just n) $ LRU.toList lru

---

__resolution'dir :: Cabal.PackageKey -> (MonadIO m, MonadReader GTDConfiguration m) => m FilePath
__resolution'dir k = do
  c <- asks _cache
  let p = Cabal.pKey k
      d = c </> p
  liftIO $ createDirectoryIfMissing False d
  return d

__resolution'path :: String -> HsModule -> (MonadIO m, MonadReader GTDConfiguration m) => m FilePath
__resolution'path n m = do
  d <- __resolution'dir $ HsModule._pkgK m
  let r = pathAsFile $ HsModule._path m
  return $ d </> (r ++ ":" ++ n)

resolution'get'generic :: String -> HsModule -> (MonadLoggerIO m, MonadReader GTDConfiguration m, Binary.Binary a) => m (Maybe a)
resolution'get'generic n m = do
  p <- __resolution'path n m
  binaryGet p

resolution'put'generic :: JSON.ToJSON a => String -> HsModule -> (Binary.Binary a, JSON.ToJSON a) => a -> (MonadLoggerIO m, MonadReader GTDConfiguration m) => m ()
resolution'put'generic n m r = do
  p <- __resolution'path n m
  liftIO $ Binary.encodeFile p r
  ll <- asks $ _logLevel . _args
  liftIO $ when (ll == LevelDebug) $ JSON.encodeFile (p ++ ".json") r

resolution'exists'generic :: String -> HsModule -> (MonadLoggerIO m, MonadReader GTDConfiguration m) => m Bool
resolution'exists'generic n m = do
  p <- __resolution'path n m
  liftIO $ doesFileExist p

resolution'get :: HsModule -> (MonadLoggerIO m, MonadReader GTDConfiguration m) => m (Maybe (Map.Map Cabal.ModuleNameS Declarations))
resolution'get = resolution'get'generic "resolution.binary"

resolution'get'lines :: HsModule -> (MonadLoggerIO m, MonadReader GTDConfiguration m) => m (Maybe Lines)
resolution'get'lines = resolution'get'generic "lines.binary"

resolution'put :: HsModule -> Map.Map Cabal.ModuleNameS Declarations -> (MonadLoggerIO m, MonadReader GTDConfiguration m) => m ()
resolution'put = resolution'put'generic "resolution.binary"

resolution'put'lines :: HsModule -> Lines -> (MonadLoggerIO m, MonadReader GTDConfiguration m) => m ()
resolution'put'lines = resolution'put'generic "lines.binary"

resolution'remove :: Cabal.Package a -> (MonadLoggerIO m, MonadReader GTDConfiguration m) => m ()
resolution'remove cPkg = do
  d <- __resolution'dir $ Cabal.key cPkg
  logDebugNSS "resolution cached remove" $ printf "%s @ %s" (show $ Cabal.key cPkg) d
  liftIO $ removeDirectoryRecursive d

resolution'exists :: HsModule -> (MonadLoggerIO m, MonadReader GTDConfiguration m) => m Bool
resolution'exists = resolution'exists'generic "resolution.binary"

resolution'exists'lines :: HsModule -> (MonadLoggerIO m, MonadReader GTDConfiguration m) => m Bool
resolution'exists'lines = resolution'exists'generic "lines.binary"
