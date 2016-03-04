-- | This module provides a type and functions for handling focus rings
-- of widgets. Note that this interface is merely provided for managing
-- the focus state for a sequence of widget names; it does not do
-- anything beyond keep track of that.
--
-- This interface is experimental.
module Brick.Focus
  ( FocusRing
  , focusRing
  , focusNext
  , focusPrev
  , focusGetCurrent
  , focusRingCursor
  , withFocusRing
  )
where

import Control.Lens ((^.))
import Data.Maybe (listToMaybe)

import Brick.Types
import Brick.Widgets.Core (Named(..))

-- | A focus ring containing a sequence of widget names to focus and a
-- currently-focused widget name.
data FocusRing n = FocusRingEmpty
                 | FocusRingNonempty ![n] !Int

-- | Construct a focus ring from the list of names.
focusRing :: [n] -> FocusRing n
focusRing [] = FocusRingEmpty
focusRing names = FocusRingNonempty names 0

-- | Advance focus to the next widget in the ring.
focusNext :: FocusRing n -> FocusRing n
focusNext FocusRingEmpty = FocusRingEmpty
focusNext (FocusRingNonempty ns i) = FocusRingNonempty ns i'
    where
        i' = (i + 1) `mod` (length ns)

-- | Advance focus to the previous widget in the ring.
focusPrev :: FocusRing n -> FocusRing n
focusPrev FocusRingEmpty = FocusRingEmpty
focusPrev (FocusRingNonempty ns i) = FocusRingNonempty ns i'
    where
        i' = (i + (length ns) - 1) `mod` (length ns)

withFocusRing :: (Eq n, Named a n) => FocusRing n -> (Bool -> a -> b) -> a -> b
withFocusRing ring f a = f (focusGetCurrent ring == Just (getName a)) a

-- | Get the currently-focused widget name from the ring. If the ring is
-- emtpy, return 'Nothing'.
focusGetCurrent :: FocusRing n -> Maybe n
focusGetCurrent FocusRingEmpty = Nothing
focusGetCurrent (FocusRingNonempty ns i) = Just $ ns !! i

-- | Cursor selection convenience function for use as an
-- 'Brick.Main.appChooseCursor' value.
focusRingCursor :: (Eq n)
                => (a -> FocusRing n)
                -- ^ The function used to get the focus ring out of your
                -- application state.
                -> a
                -- ^ Your application state.
                -> [CursorLocation n]
                -- ^ The list of available cursor positions.
                -> Maybe (CursorLocation n)
                -- ^ The cursor position, if any, that matches the name
                -- currently focused by the 'FocusRing'.
focusRingCursor getRing st ls =
    listToMaybe $ filter isCurrent ls
    where
        isCurrent cl = cl^.cursorLocationNameL ==
                       (focusGetCurrent $ getRing st)
