{-# LANGUAGE OverloadedStrings #-}
module Bump
  ( run
  , toPossibleBumps
  )
  where


import qualified Data.List as List

import qualified Deps.Diff as Diff
import qualified Deps.Registry as Registry
import qualified Elm.Details as Details
import qualified Elm.Magnitude as M
import qualified Elm.Outline as Outline
import qualified Elm.Version as V
import qualified Http
import Reporting.Doc ((<>), (<+>))
import qualified Reporting
import qualified Reporting.Doc as D
import qualified Reporting.Exit as Exit
import qualified Reporting.Exit.Help as Help
import qualified Reporting.Task as Task
import qualified Stuff



-- RUN


run :: () -> () -> IO ()
run () () =
  Reporting.attempt Exit.bumpToReport $
    Task.run (bump =<< getEnv)



-- ENV


data Env =
  Env
    { _root :: FilePath
    , _cache :: Stuff.PackageCache
    , _manager :: Http.Manager
    , _registry :: Registry.Registry
    , _outline :: Outline.Outline
    }


getEnv :: Task.Task Exit.Bump Env
getEnv =
  do  maybeRoot <- Task.io $ Stuff.findRoot
      case maybeRoot of
        Nothing ->
          Task.throw Exit.BumpNoOutline

        Just root ->
          do  cache <- Task.io $ Stuff.getPackageCache
              manager <- Task.io $ Http.getManager
              registry <- Task.eio Exit.BumpMustHaveLatestRegistry $ Registry.latest manager cache
              outlineResult <- Task.io $ Outline.read root
              case outlineResult of
                Right outline ->
                  return $ Env root cache manager registry outline

                Left problem ->
                  Task.throw $ Exit.BumpBadOutline problem



-- BUMP


bump :: Env -> Task.Task Exit.Bump ()
bump env@(Env root _ _ registry outline) =
  case outline of
    Outline.App _ ->
      Task.throw Exit.BumpApplication

    Outline.Pkg pkgOutline@(Outline.PkgOutline pkg _ _ vsn _ _ _ _) ->
      case Registry.getVersions pkg registry of
        Just knownVersions ->
          let
            bumpableVersions =
              map (\(old, _, _) -> old) (toPossibleBumps knownVersions)
          in
          if elem vsn bumpableVersions
          then suggestVersion env pkgOutline
          else
            Task.throw $ Exit.BumpUnexpectedVersion vsn $
              map head (List.group (List.sort bumpableVersions))

        Nothing ->
          Task.io $ checkNewPackage root pkgOutline



-- VALID BUMPS


toPossibleBumps :: Registry.KnownVersions -> [(V.Version, V.Version, M.Magnitude)]
toPossibleBumps (Registry.KnownVersions latest previous) =
  let
    allVersions = reverse (latest:previous)
    minorPoints = map last (List.groupBy sameMajor allVersions)
    patchPoints = map last (List.groupBy sameMinor allVersions)
  in
  (latest, V.bumpMajor latest, M.MAJOR)
  :  map (\v -> (v, V.bumpMinor v, M.MINOR)) minorPoints
  ++ map (\v -> (v, V.bumpPatch v, M.PATCH)) patchPoints


sameMajor :: V.Version -> V.Version -> Bool
sameMajor (V.Version major1 _ _) (V.Version major2 _ _) =
  major1 == major2


sameMinor :: V.Version -> V.Version -> Bool
sameMinor (V.Version major1 minor1 _) (V.Version major2 minor2 _) =
  major1 == major2 && minor1 == minor2



-- CHECK NEW PACKAGE


checkNewPackage :: FilePath -> Outline.PkgOutline -> IO ()
checkNewPackage root outline@(Outline.PkgOutline _ _ _ version _ _ _ _) =
  do  putStrLn Exit.newPackageOverview
      if version == V.one
        then
          putStrLn "The version number in elm.json is correct so you are all set!"
        else
          changeVersion root outline V.one $
            "It looks like the version in elm.json has been changed though!\n\
            \Would you like me to change it back to "
            <> D.fromVersion V.one <> "? [Y/n] "



-- SUGGEST VERSION


suggestVersion :: Env -> Outline.PkgOutline -> Task.Task Exit.Bump ()
suggestVersion (Env root cache manager _ _) outline@(Outline.PkgOutline pkg _ _ vsn _ _ _ _) =
  do  oldDocs <- Task.eio (Exit.BumpCannotFindDocs pkg vsn) (Diff.getDocs cache manager pkg vsn)
      newDocs <- error "TODO Outline.generateDocs summary"
      let changes = Diff.diff oldDocs newDocs
      let newVersion = Diff.bump changes vsn
      Task.io $ changeVersion root outline newVersion $
        let
          old = D.fromVersion vsn
          new = D.fromVersion newVersion
          mag = D.fromChars $ M.toChars (Diff.toMagnitude changes)
        in
        "Based on your new API, this should be a" <+> D.green mag <+> "change (" <> old <> " => " <> new <> ")\n"
        <> "Bail out of this command and run 'elm diff' for a full explanation.\n"
        <> "\n"
        <> "Should I perform the update (" <> old <> " => " <> new <> ") in elm.json? [Y/n] "



-- CHANGE VERSION


changeVersion :: FilePath -> Outline.PkgOutline -> V.Version -> D.Doc -> IO ()
changeVersion root outline targetVersion question =
  do  approved <- Reporting.ask question
      if not approved
        then
          putStrLn "Okay, I did not change anything!"

        else
          do  Outline.write root $ Outline.Pkg $
                outline { Outline._pkg_version = targetVersion }

              Help.toStdout $
                "Version changed to "
                <> D.green (D.fromVersion targetVersion)
                <> "!\n"
