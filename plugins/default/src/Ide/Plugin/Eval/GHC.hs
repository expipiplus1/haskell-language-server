{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-unused-imports -Wno-orphans #-}

-- |GHC API utilities
module Ide.Plugin.Eval.GHC (
    isExpr,
    addExtension,
    addImport,
    hasPackage,
    addPackages,
    modifyFlags,
    showDynFlags,
) where

import Data.List (isPrefixOf)
import Development.IDE.GHC.Compat
import qualified EnumSet
import GHC.LanguageExtensions.Type (Extension (..))
import GhcMonad (modifySession)
import GhcPlugins (DefUnitId (..), InstalledUnitId (..), fsLit, hsc_IC)
import HscTypes (InteractiveContext (ic_dflags))
import Ide.Plugin.Eval.Util (asS, gStrictTry)
import qualified Lexer
import Module (UnitId (DefiniteUnitId))
import Outputable (
    Outputable (ppr),
    SDoc,
    showSDocUnsafe,
    text,
    vcat,
    (<+>),
 )
import qualified Parser
import SrcLoc (mkRealSrcLoc)
import StringBuffer (stringToStringBuffer)

{- $setup
>>> import GHC
>>> import GHC.Paths
>>> run act = runGhc (Just libdir) (getSessionDynFlags >>= act)
>>> libdir
"/Users/titto/.stack/programs/x86_64-osx/ghc-8.10.2/lib/ghc-8.10.2"
-}

{- | Returns true if string is an expression

>>> isExprTst e df = return (isExpr df e)
>>> run $ isExprTst "3"
True

>>> run $ isExprTst "(x+y)"
True

>>> run $ isExprTst "import Data.Maybe"
False

>>> run $ isExprTst "three=3"
False
-}
isExpr :: DynFlags -> String -> Bool
isExpr df stmt = case parseThing Parser.parseExpression df stmt of
    Lexer.POk _ _ -> True
    Lexer.PFailed{} -> False

parseThing :: Lexer.P thing -> DynFlags -> String -> Lexer.ParseResult thing
parseThing parser dflags stmt = do
    let buf = stringToStringBuffer stmt
        loc = mkRealSrcLoc (fsLit "<interactive>") 1 1

    Lexer.unP parser (Lexer.mkPState dflags buf loc)

{- | True if specified package is present in DynFlags

-- >>> hasPackageTst pkg = run $ \df -> return (hasPackage df pkg)
>>> hasPackageTst pkg = run $ \_ -> addPackages [pkg] >>= return . either Left (\df -> Right (hasPackage df pkg))

>>> hasPackageTst "base"
Right True

>>> hasPackageTst "ghc"
Right True

>>> hasPackageTst "QuickCheck"
Left "<command line>: cannot satisfy -package QuickCheck\n    (use -v for more information)"
-}
hasPackage :: DynFlags -> String -> Bool
hasPackage df name =
    any
        ( \case
            ExposePackage _ (PackageArg n) _ | name `isPrefixOf` n -> True
            ExposePackage _ (UnitIdArg (DefiniteUnitId (DefUnitId (InstalledUnitId n)))) _ | name `isPrefixOf` asS n -> True
            _ -> False
        )
        $ packageFlags df

{- | Expose a list of packages
>>> addPackagesTest pkgs = run (\_ -> (packageFlags <$>) <$> addPackages pkgs)

>>> addPackagesTest []
Right []

>>> addPackagesTest ["base","array"]
Right [-package base{package base True ([])},-package array{package array True ([])}]

>>> addPackagesTest ["QuickCheck"]
Left "<command line>: cannot satisfy -package QuickCheck\n    (use -v for more information)"

>>> addPackagesTest ["notThere"]
Left "<command line>: cannot satisfy -package notThere\n    (use -v for more information)"
-}
addPackages :: [String] -> Ghc (Either String DynFlags)
addPackages pkgNames = gStrictTry $ modifyFlags (\df -> df{packageFlags = map expose pkgNames ++ packageFlags df})
  where
    expose name = ExposePackage ("-package " ++ name) (PackageArg name) (ModRenaming True []) -- -package-id filepath-1.4.2.1

modifyFlags :: GhcMonad m => (DynFlags -> DynFlags) -> m DynFlags
modifyFlags f = do
    df <- getSessionDynFlags
    _ <- setSessionDynFlags (f df)
    getSessionDynFlags

-- modifyFlags f = do
--         modifyDynFlags f
--         getSessionDynFlags

{- | Add import to evaluation context

>>> run $ \_ -> addImport "import Data.Maybe"
Could not find module ‘Data.Maybe’
Use -v (or `:set -v` in ghci) to see a list of the files searched for.

>>> run $ \df -> addPackages ["base"] >> addImport "import Data.Maybe"
[import Data.Maybe]

>>> run $ \df -> addPackages ["base"] >> addImport "import qualified Data.Maybe as M"
[import qualified Data.Maybe as M]
-}
addImport :: GhcMonad m => String -> m [InteractiveImport]
addImport i = do
    ctx <- getContext
    -- dbgO "CONTEXT" ctx
    idecl <- parseImportDecl i
    setContext $ IIDecl idecl : ctx
    -- ctx' <- getContext
    -- dbg "CONTEXT'" ctx'
    getContext

{- | Add extension to interactive evaluation session
>>> import GHC.LanguageExtensions.Type(Extension(..))
>>> run $ \_ -> addExtension DeriveGeneric
()
-}
addExtension :: GhcMonad m => Extension -> m ()
addExtension ext =
    modifySession $ \hsc -> hsc{hsc_IC = setExtension (hsc_IC hsc) ext}

setExtension :: InteractiveContext -> Extension -> InteractiveContext
setExtension ic ext = ic{ic_dflags = xopt_set (ic_dflags ic) ext}

deriving instance Read Extension

-- Partial display of DynFlags contents, for testing purposes
showDynFlags :: DynFlags -> String
showDynFlags df =
    showSDocUnsafe . vcat . map (\(n, d) -> text (n ++ ": ") <+> d) $
        [ ("extensions", ppr . extensions $ df)
        , ("extensionFlags", ppr . EnumSet.toList . extensionFlags $ df)
        , ("importPaths", vList $ importPaths df)
        -- , ("includePaths", text . show $ includePaths df)
        -- , ("packageEnv", ppr $ packageEnv df)
        -- , ("packageFlags", vcat . map ppr $ packageFlags df)
        -- ,("pkgDatabase",(map) (ppr . installedPackageId) . pkgDatabase $ df)
        -- ,("pkgDatabase",text . show <$> pkgDatabase $ df)
        ]

vList :: [String] -> SDoc
vList = vcat . map text
