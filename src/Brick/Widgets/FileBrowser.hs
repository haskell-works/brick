{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
module Brick.Widgets.FileBrowser
  ( FileBrowser(fileBrowserSelection, fileBrowserWorkingDirectory, fileBrowserEntryFilter)
  , FileInfo(..)
  , FileType(..)
  , newFileBrowser
  , setCurrentDirectory
  , renderFileBrowser
  , fileBrowserCursor
  , handleFileBrowserEvent

  -- * Lenses
  , fileBrowserWorkingDirectoryL
  , fileBrowserSelectionL
  , fileBrowserEntryFilterL
  , fileInfoFilenameL
  , fileInfoSanitizedFilenameL
  , fileInfoFilePathL
  , fileInfoFileTypeL

  -- * Attributes
  , fileBrowserAttr
  , fileBrowserCurrentDirectoryAttr
  , fileBrowserDirectoryAttr
  , fileBrowserBlockDeviceAttr
  , fileBrowserRegularFileAttr
  , fileBrowserCharacterDeviceAttr
  , fileBrowserNamedPipeAttr
  , fileBrowserSymbolicLinkAttr
  , fileBrowserSocketAttr

  -- * Filters
  , fileTypeMatch
  )
where

import Control.Monad (forM)
import Control.Monad.IO.Class (liftIO)
import Data.Char (toLower, isPrint)
import Data.Maybe (fromMaybe)
#if !(MIN_VERSION_base(4,11,0))
import Data.Monoid
#endif
import Data.List (sortBy)
import qualified Data.Vector as V
import Lens.Micro
import qualified Graphics.Vty as Vty
import qualified System.Directory as D
import qualified System.Posix.Files as U
import qualified System.FilePath as FP

import Brick.Types
import Brick.AttrMap (AttrName)
import Brick.Widgets.Core
import Brick.Widgets.List

data FileBrowser n =
    FileBrowser { fileBrowserWorkingDirectory :: FilePath
                , fileBrowserEntries :: List n FileInfo
                , fileBrowserName :: n
                , fileBrowserSelection :: Maybe FileInfo
                , fileBrowserEntryFilter :: Maybe (FileInfo -> Bool)
                }

data FileInfo =
    FileInfo { fileInfoFilename :: String
             , fileInfoSanitizedFilename :: String
             , fileInfoFilePath :: FilePath
             , fileInfoFileType :: Maybe FileType
             }
             deriving (Show, Eq, Read)

data FileType =
    RegularFile
    | BlockDevice
    | CharacterDevice
    | NamedPipe
    | Directory
    | SymbolicLink
    | Socket
    deriving (Read, Show, Eq)

suffixLenses ''FileBrowser
suffixLenses ''FileInfo

newFileBrowser :: n -> Maybe FilePath -> IO (FileBrowser n)
newFileBrowser name mCwd = do
    initialCwd <- case mCwd of
        Just path -> return path
        Nothing -> D.getCurrentDirectory

    let b = FileBrowser { fileBrowserWorkingDirectory = initialCwd
                        , fileBrowserEntries = list name mempty 1
                        , fileBrowserName = name
                        , fileBrowserSelection = Nothing
                        , fileBrowserEntryFilter = Nothing
                        }

    setCurrentDirectory initialCwd b

setCurrentDirectory :: FilePath -> FileBrowser n -> IO (FileBrowser n)
setCurrentDirectory path b = do
    let match = fromMaybe (const True) (b^.fileBrowserEntryFilterL)
    entries <- filter match <$> entriesForDirectory path
    return b { fileBrowserWorkingDirectory = path
             , fileBrowserEntries = list (b^.fileBrowserNameL) (V.fromList entries) 1
             }

entriesForDirectory :: FilePath -> IO [FileInfo]
entriesForDirectory rawPath = do
    path <- D.makeAbsolute rawPath

    -- Get all entries except "." and "..", then sort them
    dirContents <- D.listDirectory path

    infos <- forM dirContents $ \f -> do
        filePath <- D.makeAbsolute $ path FP.</> f
        status <- U.getFileStatus filePath
        return FileInfo { fileInfoFilename = f
                        , fileInfoFilePath = filePath
                        , fileInfoSanitizedFilename = sanitizeFilename f
                        , fileInfoFileType = fileTypeFromStatus status
                        }

    let dirsFirst a b = if fileInfoFileType a == Just Directory &&
                           fileInfoFileType b == Just Directory
                        then compare (toLower <$> fileInfoFilename a)
                                     (toLower <$> fileInfoFilename b)
                        else if fileInfoFileType a == Just Directory &&
                                fileInfoFileType b /= Just Directory
                             then LT
                             else if fileInfoFileType b == Just Directory &&
                                     fileInfoFileType a /= Just Directory
                                  then GT
                                  else compare (toLower <$> fileInfoFilename a)
                                               (toLower <$> fileInfoFilename b)

        allFiles = addParent $ sortBy dirsFirst infos
        parentDir = FileInfo { fileInfoFilename = ".."
                             , fileInfoSanitizedFilename = ".."
                             , fileInfoFilePath = FP.takeDirectory path
                             , fileInfoFileType = Just Directory
                             }
        addParent = if path == "/"
                    then id
                    else (parentDir :)

    return allFiles

fileTypeFromStatus :: U.FileStatus -> Maybe FileType
fileTypeFromStatus s =
    if | U.isBlockDevice s     -> Just BlockDevice
       | U.isCharacterDevice s -> Just CharacterDevice
       | U.isNamedPipe s       -> Just NamedPipe
       | U.isRegularFile s     -> Just RegularFile
       | U.isDirectory s       -> Just Directory
       | U.isSocket s          -> Just Socket
       | U.isSymbolicLink s    -> Just SymbolicLink
       | otherwise             -> Nothing

fileBrowserCursor :: FileBrowser n -> Maybe FileInfo
fileBrowserCursor b = snd <$> listSelectedElement (b^.fileBrowserEntriesL)

handleFileBrowserEvent :: (Ord n) => Vty.Event -> FileBrowser n -> EventM n (FileBrowser n)
handleFileBrowserEvent e b =
    case e of
        Vty.EvKey Vty.KEnter [] ->
            case fileBrowserCursor b of
                Nothing -> return b
                Just entry ->
                    case fileInfoFileType entry of
                        Just Directory -> liftIO $ setCurrentDirectory (fileInfoFilePath entry) b
                        _ -> return $ b & fileBrowserSelectionL .~ Just entry
        _ ->
            handleEventLensed b fileBrowserEntriesL handleListEvent e

renderFileBrowser :: (Show n, Ord n) => Bool -> FileBrowser n -> Widget n
renderFileBrowser foc b =
    let maxFilenameLength = maximum $ (length . fileInfoFilename) <$> (b^.fileBrowserEntriesL)
    in withDefAttr fileBrowserAttr $
       (withDefAttr fileBrowserCurrentDirectoryAttr $
        padRight Max $
        str $ sanitizeFilename $ fileBrowserWorkingDirectory b) <=>
       renderList (renderFileInfo maxFilenameLength) foc (b^.fileBrowserEntriesL)

renderFileInfo :: Int -> Bool -> FileInfo -> Widget n
renderFileInfo maxLen _ info =
    padRight Max body
    where
        addAttr = maybe id (withDefAttr . attrForFileType) (fileInfoFileType info)
        body = addAttr (hLimit (maxLen + 1) $ padRight Max $ str $ fileInfoSanitizedFilename info)

-- | Sanitize a filename for terminal display, replacing non-printable
-- characters with '?'.
sanitizeFilename :: String -> String
sanitizeFilename = fmap toPrint
    where
        toPrint c | isPrint c = c
                  | otherwise = '?'

attrForFileType :: FileType -> AttrName
attrForFileType RegularFile = fileBrowserRegularFileAttr
attrForFileType BlockDevice = fileBrowserBlockDeviceAttr
attrForFileType CharacterDevice = fileBrowserCharacterDeviceAttr
attrForFileType NamedPipe = fileBrowserNamedPipeAttr
attrForFileType Directory = fileBrowserDirectoryAttr
attrForFileType SymbolicLink = fileBrowserSymbolicLinkAttr
attrForFileType Socket = fileBrowserSocketAttr

fileBrowserAttr :: AttrName
fileBrowserAttr = "fileBrowser"

fileBrowserCurrentDirectoryAttr :: AttrName
fileBrowserCurrentDirectoryAttr = fileBrowserAttr <> "currentDirectory"

fileBrowserDirectoryAttr :: AttrName
fileBrowserDirectoryAttr = fileBrowserAttr <> "directory"

fileBrowserBlockDeviceAttr :: AttrName
fileBrowserBlockDeviceAttr = fileBrowserAttr <> "block"

fileBrowserRegularFileAttr :: AttrName
fileBrowserRegularFileAttr = fileBrowserAttr <> "regular"

fileBrowserCharacterDeviceAttr :: AttrName
fileBrowserCharacterDeviceAttr = fileBrowserAttr <> "char"

fileBrowserNamedPipeAttr :: AttrName
fileBrowserNamedPipeAttr = fileBrowserAttr <> "pipe"

fileBrowserSymbolicLinkAttr :: AttrName
fileBrowserSymbolicLinkAttr = fileBrowserAttr <> "symlink"

fileBrowserSocketAttr :: AttrName
fileBrowserSocketAttr = fileBrowserAttr <> "socket"

fileTypeMatch :: [FileType] -> FileInfo -> Bool
fileTypeMatch tys i = maybe False (`elem` tys) $ fileInfoFileType i