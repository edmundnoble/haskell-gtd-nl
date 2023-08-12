{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# HLINT ignore "Avoid lambda" #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

module GTD.Cabal where

import Control.Concurrent.Async.Lifted (forConcurrently)
import Control.Lens (At (..), makeLenses, use, view, (%=), (.=))
import Control.Monad (forM, forM_)
import Control.Monad.Except (MonadError (..))
import Control.Monad.Logger (MonadLogger, MonadLoggerIO (..))
import Control.Monad.RWS (MonadReader (..), MonadWriter (..), asks, MonadState)
import Control.Monad.State (StateT (..), MonadState (put))
import qualified Control.Monad.State.Lazy as State
import Control.Monad.Trans (MonadIO (liftIO))
import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.Trans.Maybe (MaybeT (..))
import Control.Monad.Trans.Writer (execWriter, execWriterT)
import Data.Aeson (FromJSON, ToJSON)
import Data.Binary (encodeFile)
import qualified Data.ByteString.UTF8 as BS
import Data.List (find)
import qualified Data.Map as Map
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import Distribution.Compat.Prelude (Binary, Generic, fromMaybe)
import Distribution.Package (PackageIdentifier (..), packageName, unPackageName)
import Distribution.PackageDescription (BuildInfo (..), LibraryName (..), unUnqualComponentName)
import qualified Distribution.PackageDescription as Cabal (BuildInfo (..), Dependency (..), Executable (..), Library (..), PackageDescription (..), explicitLibModules, unPackageName)
import Distribution.PackageDescription.Configuration (flattenPackageDescription)
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription, runParseResult)
import Distribution.Pretty (prettyShow)
import Distribution.Utils.Path (getSymbolicPath)
import GTD.Configuration (GTDConfiguration (_repos, _cache), repos)
import GTD.Resolution.State.Caching.Utils (binaryGet, pathAsFile)
import GTD.Utils (deduplicate, logDebugNSS, logDebugNSS')
import System.Directory (listDirectory)
import System.FilePath (takeDirectory, takeExtension, (</>))
import System.IO (IOMode (ReadMode), hGetContents, openFile)
import System.Process (CreateProcess (..), StdStream (CreatePipe), createProcess, proc, waitForProcess)
import Text.Printf (printf)
import Text.Regex.Posix ((=~))

---

data GetCache = GetCache
  { _vs :: Map.Map String (Maybe FilePath),
    _changed :: Bool
  }
  deriving (Show, Generic)

$(makeLenses ''GetCache)

instance FromJSON GetCache

instance ToJSON GetCache

instance Semigroup GetCache where
  (<>) :: GetCache -> GetCache -> GetCache
  (GetCache vs1 c1) <> (GetCache vs2 c2) = GetCache (vs1 <> vs2) (c1 || c2)

instance Monoid GetCache where
  mempty :: GetCache
  mempty = GetCache mempty False

-- executes `cabal get` on given `pkg + pkgVerPredicate`
get :: String -> String -> (MonadIO m, MonadLogger m, MonadState GetCache m, MonadReader GTDConfiguration m) => MaybeT m FilePath
get pkg pkgVerPredicate = do
  let k = pkg ++ pkgVerPredicate
  r0 <- use $ vs . at k
  case r0 of
    Just p -> MaybeT $ return p
    Nothing -> do
      reposR <- view repos
      (_, Just hout, Just herr, h) <- liftIO $ createProcess (proc "cabal" ["get", k, "--destdir", reposR]) {std_out = CreatePipe, std_err = CreatePipe}
      stdout <- liftIO $ hGetContents hout
      stderr <- liftIO $ hGetContents herr
      let content = stdout ++ stderr
      let re = pkg ++ "-" ++ "[^\\/]*\\/"
      let packageVersion :: [String] = (=~ re) <$> lines content
      ec <- liftIO $ waitForProcess h
      logDebugNSS' "cabal get" $ printf "cabal get %s %s: exit code %s" pkg pkgVerPredicate (show ec)

      let r = find (not . null) packageVersion
      vs %= Map.insert k r
      changed .= True

      MaybeT $ return r

---

type PackageNameS = String

type ModuleNameS = String

data DesignationType = Library | Executable | TestSuite | Benchmark
  deriving (Eq, Ord, Show, Generic)

data Designation = Designation {_desName :: Maybe String, _desType :: DesignationType}
  deriving (Eq, Ord, Show, Generic)

instance FromJSON Designation

instance FromJSON DesignationType

instance ToJSON Designation

instance ToJSON DesignationType

instance Binary DesignationType

instance Binary Designation

dKey :: Designation -> String
dKey d = case _desType d of
  Library -> "lib:" ++ fromMaybe "" (_desName d)
  Executable -> "exe:" ++ fromMaybe "" (_desName d)
  TestSuite -> "test:" ++ fromMaybe "" (_desName d)
  Benchmark -> "bench:" ++ fromMaybe "" (_desName d)

data Dependency = Dependency
  { _dName :: PackageNameS,
    _dVersion :: String,
    _dSubname :: Maybe String
  }
  deriving (Show, Eq, Ord, Generic)

$(makeLenses ''Dependency)

instance Binary Dependency

dAsT :: Dependency -> (PackageNameS, String, Maybe String)
dAsT d = (_dName d, _dVersion d, _dSubname d)

data PackageModules = PackageModules
  { _srcDirs :: [FilePath],
    _allKnownModules :: Set.Set ModuleNameS,
    _exports :: Set.Set ModuleNameS,
    _reExports :: Set.Set ModuleNameS
  }
  deriving (Eq, Show, Generic)

$(makeLenses ''PackageModules)

emptyPackageModules :: PackageModules
emptyPackageModules = PackageModules [] Set.empty Set.empty Set.empty

instance Binary PackageModules

type PackageWithResolvedDependencies = Package (Package Dependency)

type PackageWithUnresolvedDependencies = Package Dependency

data Package a = Package
  { _designation :: Designation,
    _name :: PackageNameS,
    _version :: String,
    _root :: FilePath,
    _modules :: PackageModules,
    _dependencies :: [a]
  }
  deriving (Show, Generic)

instance Binary (Package (Package Dependency))

instance Binary (Package Dependency)

data PackageKey = PackageKey
  { _pkName :: PackageNameS,
    _pkVersion :: String,
    _pkDesignation :: Designation
  }
  deriving (Show, Eq, Ord, Generic)

instance Binary PackageKey

instance FromJSON PackageKey

instance ToJSON PackageKey

emptyPackageKey :: PackageKey
emptyPackageKey = PackageKey "" "" (Designation Nothing Library)

key :: Package a -> PackageKey
key p = PackageKey {_pkName = _name p, _pkVersion = _version p, _pkDesignation = _designation p}

pKey :: PackageKey -> String
pKey k = _pkName k ++ "-" ++ _pkVersion k ++ "-" ++ dKey (_pkDesignation k)

---

__read'cache'get :: FilePath -> (MonadLoggerIO m, MonadReader GTDConfiguration m) => m (Maybe [PackageWithUnresolvedDependencies])
__read'cache'get = binaryGet

__read'cache'put :: FilePath -> [PackageWithUnresolvedDependencies] -> (MonadIO m) => m ()
__read'cache'put p r = liftIO $ encodeFile p r

__read :: FilePath -> (MonadLoggerIO m, MonadReader GTDConfiguration m) => m [PackageWithUnresolvedDependencies]
__read p = do
  __read'cache'get p >>= \case
    Just r -> return r
    Nothing -> do
      c <- asks _cache
      let pc = c </> pathAsFile p
      r <- __read'direct p
      __read'cache'put pc r
      return r

__read'direct :: FilePath -> (MonadLoggerIO m) => m [PackageWithUnresolvedDependencies]
__read'direct p = do
  logDebugNSS "cabal read" p
  handle <- liftIO $ openFile p ReadMode
  (warnings, epkg) <- liftIO $ runParseResult . parseGenericPackageDescription . BS.fromString <$> hGetContents handle
  forM_ warnings (\w -> logDebugNSS "cabal read" $ "got warnings for `" ++ p ++ "`: " ++ show w)
  pd <- liftIO $ either (fail . show) (return . flattenPackageDescription) epkg

  execWriterT $ do
    -- TODO: benchmarks, test suites
    let p0 =
          Package
            { _name = unPackageName $ packageName pd,
              _version = prettyShow $ pkgVersion $ Cabal.package pd,
              _root = takeDirectory p,
              _designation = Designation {_desType = Library, _desName = Nothing},
              _modules = emptyPackageModules,
              _dependencies = []
            }
    let lh lib = tell . pure $ do
          p0
            { _designation = Designation {_desType = Library, _desName = libraryNameToDesignationName $ Cabal.libName lib},
              _modules = __exportsL lib,
              _dependencies = __depsU $ Cabal.libBuildInfo lib
            }
    forM_ (Cabal.library pd) lh
    forM_ (Cabal.subLibraries pd) lh
    forM_ (Cabal.executables pd) $ \exe -> tell . pure $ do
      p0
        { _designation = Designation {_desType = Executable, _desName = Just $ unUnqualComponentName $ Cabal.exeName exe},
          _modules = __exportsE exe,
          _dependencies = __depsU $ Cabal.buildInfo exe
        }

findAt ::
  FilePath ->
  (MonadLoggerIO m, MonadReader GTDConfiguration m, MonadError String m) => m [PackageWithUnresolvedDependencies]
findAt wd = do
  cabalFiles <- liftIO $ filter (\x -> takeExtension x == ".cabal") <$> listDirectory wd
  cabalFile <- case length cabalFiles of
    0 -> throwError "No cabal file found"
    1 -> return $ wd </> head cabalFiles
    _ -> throwError "Multiple cabal files found"
  logDebugNSS "definition" $ "Found cabal file: " ++ cabalFile
  __read cabalFile

---

__exportsL :: Cabal.Library -> PackageModules
__exportsL lib =
  PackageModules
    { _srcDirs = getSymbolicPath <$> (hsSourceDirs . Cabal.libBuildInfo) lib,
      _exports = Set.fromList $ prettyShow <$> Cabal.exposedModules lib,
      _reExports = Set.fromList $ prettyShow <$> Cabal.reexportedModules lib,
      _allKnownModules = Set.fromList $ prettyShow <$> Cabal.explicitLibModules lib
    }

__exportsE :: Cabal.Executable -> PackageModules
__exportsE exe =
  PackageModules
    { _srcDirs = getSymbolicPath <$> (hsSourceDirs . Cabal.buildInfo) exe,
      _exports = Set.empty,
      _reExports = Set.empty,
      _allKnownModules = Set.fromList $ "Main" : (prettyShow <$> Cabal.otherModules (Cabal.buildInfo exe))
    }

libraryNameToDesignationName :: LibraryName -> Maybe String
libraryNameToDesignationName LMainLibName = Nothing
libraryNameToDesignationName (LSubLibName n) = Just $ unUnqualComponentName n

__depsU :: BuildInfo -> [Dependency]
__depsU i = execWriter $
  forM_ (targetBuildDepends i) $ \(Cabal.Dependency p vP ns) ->
    forM_ ns \n ->
      tell $ pure $ Dependency {_dName = Cabal.unPackageName p, _dVersion = prettyShow vP, _dSubname = libraryNameToDesignationName n}

---

full :: PackageWithUnresolvedDependencies -> (MonadBaseControl IO m, MonadLoggerIO m, MonadState GetCache m, MonadReader GTDConfiguration m) => m PackageWithResolvedDependencies
full pkg = do
  logDebugNSS "cabal fetch" $ _name pkg
  let deps = _dependencies pkg
  let namesWithPredicates = deduplicate $ (\(Dependency {_dName = n, _dVersion = v}) -> (n, v)) <$> deps
  logDebugNSS "cabal fetch" $ "dependencies: " ++ show namesWithPredicates
  st <- State.get
  pkgs <-
    let fetchDependency n vp = (,,) n vp <$> get n vp
        fetchDependencies ds = do
          (nameToPathMs, caches) <- unzip <$> forConcurrently ds (flip runStateT st . runMaybeT . uncurry fetchDependency)
          put $ foldr (<>) st caches
          return $ catMaybes nameToPathMs
     in fetchDependencies namesWithPredicates
  reposR <- asks _repos
  depsF <- fmap (Map.fromList . concat) $ forM pkgs $ \(n, v, p) -> do
    r <- __read $ reposR </> p </> (n ++ ".cabal")
    let libs = filter ((== Library) . _desType . _designation) r
    return $ fmap (\l -> (,) (n, v, _desName . _designation $ l) l) libs
  let depsR = Map.restrictKeys depsF (Set.fromList $ dAsT <$> deps)
  return $ pkg {_dependencies = Map.elems depsR}
