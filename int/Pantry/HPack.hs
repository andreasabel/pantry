{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Pantry.HPack
  ( hpack
  , hpackVersion
  ) where

import qualified Data.ByteString.Lazy.Char8 as BL
import           Data.Char ( isDigit, isSpace )
import qualified Hpack
import qualified Hpack.Config as Hpack
import           Pantry.Types
                   ( HasPantryConfig, HpackExecutable (..), PantryConfig (..)
                   , Version, pantryConfigL, parseVersionThrowing
                   )
import           Path
                   ( Abs, Dir, Path, (</>), filename, parseRelFile, toFilePath )
import           Path.IO ( doesFileExist )
import           RIO
import           RIO.Process
                   ( HasProcessContext, proc, readProcessStdout_, runProcess_
                   , withWorkingDir
                   )

hpackVersion ::
     (HasPantryConfig env, HasLogFunc env, HasProcessContext env)
  => RIO env Version
hpackVersion = do
  he <- view $ pantryConfigL.to pcHpackExecutable
  case he of
    HpackBundled -> do
      let bundledHpackVersion :: String = VERSION_hpack
      parseVersionThrowing bundledHpackVersion
    HpackCommand command -> do
      version <- BL.unpack <$> proc command ["--version"] readProcessStdout_
      let version' = dropWhile (not . isDigit) version
          version'' = filter (not . isSpace) version'
      parseVersionThrowing version''

-- | Generate .cabal file from package.yaml, if necessary.
hpack ::
     (HasPantryConfig env, HasLogFunc env, HasProcessContext env)
  => Path Abs Dir
  -> RIO env ()
hpack pkgDir = do
  packageConfigRelFile <- parseRelFile Hpack.packageConfig
  let hpackFile = pkgDir Path.</> packageConfigRelFile
  whenM (doesFileExist hpackFile) $ do
    logDebug $ "Running hpack on " <> fromString (toFilePath hpackFile)
    he <- view $ pantryConfigL.to pcHpackExecutable
    case he of
      HpackBundled -> do
        r <- liftIO $ Hpack.hpackResult $ Hpack.setProgramName "stack" $
          Hpack.setTarget (toFilePath hpackFile) Hpack.defaultOptions
        forM_ (Hpack.resultWarnings r) (logWarn . fromString)
        let cabalFile = fromString . Hpack.resultCabalFile $ r
        case Hpack.resultStatus r of
          Hpack.Generated -> logDebug $
               "hpack generated a modified version of "
            <> cabalFile
          Hpack.OutputUnchanged -> logDebug $
               "hpack output unchanged in "
            <> cabalFile
          Hpack.AlreadyGeneratedByNewerHpack -> logWarn $
               cabalFile
            <> " was generated with a newer version of hpack. Ignoring "
            <> fromString (toFilePath hpackFile)
            <> " in favor of the Cabal file.\n"
            <> "Either please upgrade and try again or, if you want to use the "
            <> fromString (toFilePath (filename hpackFile))
            <> " file instead of the Cabal file,\n"
            <> "then please delete the Cabal file."
          Hpack.ExistingCabalFileWasModifiedManually -> logWarn $
               cabalFile
            <> " was modified manually. Ignoring "
            <> fromString (toFilePath hpackFile)
            <> " in favor of the Cabal file.\n"
            <> "If you want to use the "
            <> fromString (toFilePath (filename hpackFile))
            <> " file instead of the Cabal file,\n"
            <> "then please delete the Cabal file."
      HpackCommand command ->
        withWorkingDir (toFilePath pkgDir) $
        proc command [] runProcess_
