{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

module GTD.Haskell.Module where

import Control.Exception (IOException, try)
import Control.Lens (makeLenses)
import Control.Monad.Except (MonadError (..), liftEither)
import Control.Monad.Logger (MonadLoggerIO)
import Control.Monad.State (MonadIO (..), StateT (runStateT))
import Control.Monad.Trans.Writer (execWriterT)
import Data.Aeson (FromJSON, ToJSON)
import Data.Either.Combinators (mapLeft)
import qualified Data.Map.Strict as Map
import GHC.Generics (Generic)
import GTD.Cabal (ModuleNameS, PackageNameS)
import GTD.Haskell.Cpphs (haskellApplyCppHs)
import GTD.Haskell.Declaration (ClassOrData (_cdtName), Declaration (_declModule, _declName), Declarations (..), Exports, Imports)
import qualified GTD.Haskell.Declaration as Declarations
import qualified GTD.Haskell.Parser.GhcLibParser as GHC
import GTD.Utils (logDebugNSS)
import Language.Haskell.Exts (Module (Module), SrcSpan (..), SrcSpanInfo (..))

newtype HsModuleParams = HsModuleParams
  { _isImplicitExportAll :: Bool
  }
  deriving (Show, Eq, Generic)

emptyParams :: HsModuleParams
emptyParams = HsModuleParams {_isImplicitExportAll = False}

instance FromJSON HsModuleParams

instance ToJSON HsModuleParams

data HsModuleData = HsModuleData
  { _exports0 :: Exports,
    _imports :: Imports,
    _locals :: Declarations
  }
  deriving (Show, Eq, Generic)

instance FromJSON HsModuleData

instance ToJSON HsModuleData

emptyData :: HsModuleData
emptyData = HsModuleData {_exports0 = Map.empty, _imports = Map.empty, _locals = Declarations {_decls = Map.empty, _dataTypes = Map.empty}}

data HsModule = HsModule
  { _package :: PackageNameS,
    _name :: ModuleNameS,
    _path :: FilePath,
    _info :: HsModuleData,
    _params :: HsModuleParams
  }
  deriving (Show, Eq, Generic)

$(makeLenses ''HsModule)

instance FromJSON HsModule

instance ToJSON HsModule

emptySrcSpan :: SrcSpan
emptySrcSpan = SrcSpan {srcSpanFilename = "", srcSpanStartLine = 0, srcSpanStartColumn = 0, srcSpanEndLine = 0, srcSpanEndColumn = 0}

emptySrcSpanInfo :: SrcSpanInfo
emptySrcSpanInfo = SrcSpanInfo {srcInfoSpan = emptySrcSpan, srcInfoPoints = []}

emptyHaskellModule :: Module SrcSpanInfo
emptyHaskellModule = Module emptySrcSpanInfo Nothing [] [] []

emptyHsModule :: HsModule
emptyHsModule =
  HsModule
    { _package = "",
      _name = "",
      _path = "",
      _info = emptyData,
      _params = emptyParams
    }

parseModule :: HsModule -> (MonadLoggerIO m, MonadError String m) => m HsModule
parseModule cm@HsModule {_path = srcP} = do
  let logTag = "parsing module " ++ srcP
  logDebugNSS logTag ""

  src <- liftEither . mapLeft show =<< liftIO (try $ readFile srcP :: IO (Either IOException String))
  srcPostCpp <- haskellApplyCppHs srcP src

  aE <- liftIO $ GHC.parse srcP srcPostCpp
  a <- case aE of
    Left err -> throwError err
    Right a -> return a
  (iiea, es) <- runStateT (GHC.exports a) Map.empty
  is <- execWriterT $ GHC.imports a
  locals <- execWriterT $ GHC.identifiers a
  return $
    cm
      { _info = HsModuleData {_exports0 = es, _imports = is, _locals = locals},
        _params = HsModuleParams {_isImplicitExportAll = iiea},
        _name = GHC.name a
      }

---

newtype HsModuleP = HsModuleP
  { _exports :: Declarations
  }
  deriving (Show, Eq, Generic)

$(makeLenses ''HsModuleP)

instance FromJSON HsModuleP

instance ToJSON HsModuleP

---

resolve :: Map.Map ModuleNameS HsModuleP -> Declaration -> Maybe Declaration
resolve moduleDecls orig = do
  m <- _declModule orig `Map.lookup` moduleDecls
  _declName orig `Map.lookup` (Declarations._decls . _exports) m

resolveCDT :: Map.Map ModuleNameS HsModuleP -> ClassOrData -> Maybe ClassOrData
resolveCDT moduleDecls orig = do
  m <- (_declModule . _cdtName) orig `Map.lookup` moduleDecls
  (_declName . _cdtName) orig `Map.lookup` (Declarations._dataTypes . _exports) m
