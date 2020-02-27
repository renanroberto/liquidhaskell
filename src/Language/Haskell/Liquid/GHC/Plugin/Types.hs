{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}

module Language.Haskell.Liquid.GHC.Plugin.Types
    ( SpecComment(..)

    -- * Dealing with specs and their dependencies
    , LiquidLib
    , mkLiquidLib
    , libTarget
    , libDeps
    , allDeps
    , addLibDependencies

    -- * Caching specs into interfaces
    , CachedSpec
    , toCached
    , cachedSpecStableModuleId
    , cachedSpecModule
    , fromCached

    -- * Merging specs together
    , mergeSpecs
    , nullSpec

    -- * Acquiring and manipulating data from the typechecking phase
    , TcData
    , tcAllImports
    , tcQualifiedImports
    , tcResolvedNames
    , mkTcData

    -- * Wrapper type to talk about unoptimised things
    , Unoptimised(fromUnoptimised)
    , toUnoptimised

    , debugShowModule
    ) where

import           Data.Binary                             as B
import           Data.Data                                ( Data )
import           Data.Foldable
import           Text.Parsec                              ( SourcePos )
import           Outputable                        hiding ( (<>) )
import           GHC.Generics                      hiding ( moduleName )
import qualified Language.Haskell.Liquid.GHC.GhcMonadLike as GhcMonadLike
import           GHC                                      ( LImportDecl
                                                          , GhcRn
                                                          , Name
                                                          , TyThing
                                                          )
import           HscTypes                                 ( ModGuts )
import           TcRnTypes                                ( TcGblEnv(tcg_rn_imports) )
import           UniqFM
import           Module                                   ( ModuleName
                                                          , UnitId
                                                          , Module(..)
                                                          , moduleName
                                                          , moduleUnitId
                                                          , unitIdString
                                                          , moduleNameString
                                                          , mkModuleName
                                                          , stringToUnitId
                                                          , moduleStableString
                                                          , stableModuleCmp
                                                          )

import           Data.Map                                 ( Map )
import qualified Data.Map.Strict                         as M
import qualified Data.HashSet        as HS
import           Data.HashSet                             ( HashSet )
import           Data.Hashable
import qualified Data.Text.Lazy                          as TL

import           Language.Fixpoint.Types.Spans
import           Language.Haskell.Liquid.Types.Types
import           Language.Haskell.Liquid.Types.Specs      ( QImports )
import           Language.Haskell.Liquid.Measure          ( BareSpec, Spec(..) )
import qualified Language.Haskell.Liquid.GHC.Interface   as LH
import           Language.Fixpoint.Types.Names            ( Symbol )


import qualified Data.List as L


data LiquidLib = LiquidLib
  {  llTarget :: BareSpec
  -- ^ The target 'BareSpec'.
  ,  llDeps   :: HashSet CachedSpec
  -- ^ The specs which were necessary to produce the target 'BareSpec'.
  } deriving (Show, Generic)

instance B.Binary LiquidLib

-- | Creates a new 'LiquidLib' with no dependencies.
mkLiquidLib :: BareSpec -> LiquidLib
mkLiquidLib s = LiquidLib s mempty

-- | Adds a set of dependencies to the input 'LiquidLib'.
addLibDependencies :: HashSet CachedSpec -> LiquidLib -> LiquidLib
addLibDependencies deps lib = lib { llDeps = deps <> (llDeps lib) }

-- | Returns the target 'BareSpec' of this 'LiquidLib'.
libTarget :: LiquidLib -> BareSpec
libTarget = llTarget

-- | Returns all the dependencies of this 'LiquidLib'.
libDeps :: LiquidLib -> HashSet CachedSpec
libDeps = llDeps

-- | Extracts all the dependencies from a collection of 'LiquidLib's.
allDeps :: Foldable f => f LiquidLib -> HashSet CachedSpec
allDeps = foldl' (\acc lib -> acc <> llDeps lib) mempty

-- | A newtype wrapper around a 'Module' which:
--
-- * Allows a 'Module' to be serialised (i.e. it has a 'Binary' instance)
-- * It tries to use stable comparison and equality under the hood.
--
newtype StableModule = StableModule Module

instance Ord StableModule where
  (StableModule m1) `compare` (StableModule m2) = stableModuleCmp m1 m2

instance Eq StableModule where
  (StableModule m1) == (StableModule m2) = (m1 `stableModuleCmp` m2) == EQ

instance Show StableModule where
    show (StableModule mdl) = "Stable" ++ debugShowModule mdl

-- | Converts a 'Module' into a 'StableModule'.
toStableModule :: Module -> StableModule
toStableModule = StableModule

instance Binary StableModule where
    put (StableModule mdl) = do
      put (unitIdString . moduleUnitId $ mdl)
      put (moduleNameString . moduleName $ mdl)

    get = do
      uidStr <- get
      mnStr  <- get
      pure $ StableModule (Module (stringToUnitId uidStr) (mkModuleName mnStr))


-- | A cached spec which can be serialised into an interface.
--
-- /INVARIANT/: A 'CachedSpec' has temination-checking disabled 
-- (i.e. 'noTerm' is called on the inner 'BareSpec').
data CachedSpec = CachedSpec StableModule BareSpec deriving (Show, Generic)

instance Binary CachedSpec

instance Eq CachedSpec where
    (CachedSpec id1 _) == (CachedSpec id2 _) = id1 == id2

instance Hashable CachedSpec where
    hashWithSalt s (CachedSpec (StableModule mdl) _) = 
      hashWithSalt s (moduleStableString mdl)

-- | Converts the input 'BareSpec' into a 'CachedSpec', inforcing the invariant that termination checking
-- needs to be disabled as this is now considered safe to use for \"clients\".
toCached :: Module -> BareSpec -> CachedSpec
toCached mdl bareSpec = CachedSpec (toStableModule mdl) (LH.noTerm bareSpec)

cachedSpecStableModuleId :: CachedSpec -> String
cachedSpecStableModuleId (CachedSpec (StableModule m) _) = moduleStableString m

cachedSpecModule :: CachedSpec -> Module
cachedSpecModule (CachedSpec (StableModule m) _) = m

fromCached :: CachedSpec -> (ModName, BareSpec)
fromCached (CachedSpec (StableModule mdl) s) = (ModName SrcImport (moduleName mdl), s)

--
-- Merging specs together.
--

-- | Temporary hacky newtype wrapper that gives an 'Eq' instance to a type based on the 'Binary' encoding
-- representation.
newtype HackyEQ  a = HackyEQ  { unHackyEQ :: a }

instance Binary a => Eq (HackyEQ a) where
  (HackyEQ a) == (HackyEQ b) = B.encode a == B.encode b

instance Binary a => Hashable (HackyEQ a) where
  hashWithSalt s (HackyEQ a) = hashWithSalt s (B.encode a)

-- | Checks if the two input declarations are equal, by checking not only that their value
-- is the same, but also that they are declared exactly in the same place.
sameDeclaration :: (Loc a, Eq a) => a -> a -> Bool
sameDeclaration x1 x2 = x1 == x2 && (srcSpan x1 == srcSpan x2)

-- | Merges two 'BareSpec's together.
-- NOTE(adinapoli) In theory what we would like is to have a version of this function that is either
-- isomorphic to 'mappend' or not use these hacks (i.e. 'nubBy', etc).
mergeSpecs :: BareSpec -> BareSpec -> BareSpec
mergeSpecs s1 s2 = LH.noTerm $
  (s1 <> s2) { 
      sigs      = L.nubBy (\a b -> fst a == fst b) (sigs s1 <> sigs s2)
    , dataDecls = L.nubBy sameDeclaration (dataDecls s1 <> dataDecls s2)
    }

-- | Returns 'True' if the input 'BareSpec' is empty.
-- FIXME(adinapoli) Currently this uses the 'HackEQ' under the hook, which is bad.
nullSpec :: BareSpec -> Bool
nullSpec spec = HackyEQ spec == HackyEQ mempty

-- | Just a small wrapper around the 'SourcePos' and the text fragment of a LH spec comment.
newtype SpecComment =
    SpecComment (SourcePos, String)
    deriving Data

newtype Unoptimised a = Unoptimised { fromUnoptimised :: a }

toUnoptimised :: a -> Unoptimised a
toUnoptimised = Unoptimised

-- | Data which can be \"safely\" passed to the \"Core\" stage of the pipeline.
-- The notion of \"safely\" here is a bit vague: things like imports are somewhat
-- guaranteed not to change, but things like identifiers might, so they shouldn't
-- land here.
data TcData = TcData {
    tcAllImports       :: HS.HashSet Symbol
  , tcQualifiedImports :: QImports
  , tcResolvedNames    :: [(Name, Maybe TyThing)]
  }

instance Outputable TcData where
    ppr (TcData{..}) = 
          text "TcData { imports  = " <+> text (show $ HS.toList tcAllImports)
      <+> text "       , qImports = " <+> text (show tcQualifiedImports)
      <+> text "       , names    = " <+> ppr tcResolvedNames
      <+> text " }"

-- | Constructs a 'TcData' out of a 'TcGblEnv'.
mkTcData :: GhcMonadLike.TypecheckedModule -> [(Name, Maybe TyThing)] -> TcData
mkTcData tcModule resolvedNames = TcData {
    tcAllImports       = LH.allImports       (GhcMonadLike.tm_renamed_source tcModule)
  , tcQualifiedImports = LH.qualifiedImports (GhcMonadLike.tm_renamed_source tcModule)
  , tcResolvedNames    = resolvedNames
  }

debugShowModule :: Module -> String
debugShowModule m = showSDocUnsafe $
                     text "Module { unitId = " <+> ppr (moduleUnitId m)
                 <+> text ", name = " <+> ppr (moduleName m) 
                 <+> text " }"