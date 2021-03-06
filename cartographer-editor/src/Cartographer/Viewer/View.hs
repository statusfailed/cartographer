{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | This module defines how cartographer hypergraphs are rendered to SVG.
-- Here is a brief overview of the rendering approach.
--
-- The Cartographer.Layout keeps geometry information in "abstract"
-- coordinates- an integer grid, with no space for wires.
--
-- Cartographer.Draw is a simpler interface to Layout- namely, the Renderable
-- type can be used to draw all elements of the diagram individually.
--
-- This module makes two more transforms to get to the final screen
-- coordinates:
--  1) "make space" for wires, by interspersing an empty column between all
--      generator columns.
--  2) Scale up to pixel coordinates
module Cartographer.Viewer.View where

import Miso (View(..))
import qualified Miso as Miso
import Miso.String (ms)
import qualified Miso.String as MS
import qualified Miso.Svg as Svg

import Data.String

import Linear.Vector ((*^))
import Linear.V2 (V2(..))

import Data.Bimap (Bimap)
import qualified Data.Bimap as Bimap

import Data.Hypergraph
  ( HyperEdgeId, MatchState(..), emptyMatchState, Wire(..), Open(..), Port(..)
  , PortRole(..)
  )
import Cartographer.Layout (Layout, Tile(..))
import qualified Cartographer.Layout as Layout

import Cartographer.Types.Grid (Position)

import Cartographer.Draw (Renderable(..))
import qualified Cartographer.Draw as Draw

import Data.Equivalence (Equivalence)
import qualified Data.Equivalence as Equivalence

import Cartographer.Viewer.Drawing
import Cartographer.Viewer.Types

import Cartographer.Viewer.Model (toAction)

viewWith
  :: MatchState Generator -> Layout Generator -> ViewerOptions -> View Action
viewWith m layout opts = flip toAction layout <$> viewRawWith m layout opts

view :: Layout Generator -> ViewerOptions -> View Action
view = viewWith emptyMatchState

viewRawWith
  :: MatchState Generator
  -> Layout Generator
  -> ViewerOptions
  -> View RawAction
viewRawWith m layout opts
  = flip (viewRenderableWith m) opts . Draw.toGridCoordinates $ layout

viewRaw :: Layout Generator -> ViewerOptions -> View RawAction
viewRaw = viewRawWith emptyMatchState

viewRenderable
  :: Draw.Renderable Generator Position -> ViewerOptions -> View RawAction
viewRenderable = viewRenderableWith emptyMatchState

viewRenderableWith
  :: MatchState Generator
  -> Draw.Renderable Generator Position
  -> ViewerOptions
  -> View RawAction
viewRenderableWith m (Renderable tiles wires dimensions) opts =
  -- NOTE: order here is very important for clickability!
  -- If anything is above clickableGridSquares, then not all squares are
  -- clickable!
  -- NOTE: we also increase the grid height by an extra tile, so there are
  -- always at least 2 grid squares high available for clicking - otherwise
  -- it's very annoying to draw twists. Maybe in future its better to let the
  -- user explicitly size the diagram?
  Svg.svg_ svgAttrs
    [ if (showGrid opts) then rulers else Svg.g_ [] []
    , viewBoundaries spacedDims opts
    , Svg.g_ [] (fmap g wires)
    , Svg.g_ [] (fmap f tiles)
    , clickableGridSquares spacedDims unitSize
    ]
  where
    rulers = gridLines unitSize (scaledDims + V2 0 unitSize)
    unitSize = fromIntegral (tileSize opts)
    f (t, v)      = viewTile m t v opts
    g (w,(v1,v2)) = viewWire m w v1 v2 opts

  -- intersperse a "wires" col between every generator
  -- NOTE: the (- V2 1 0) removes the final unnecessary "wires" column from the
  -- grid, and the (+ V2 0 1) adds an extra row of tiles.
    spacedDims = V2 2 1 * dimensions - V2 1 0 + V2 0 1
    scaledDims = fmap fromIntegral (tileSize opts *^ spacedDims)
    V2 imgWidth imgHeight = scaledDims + V2 0 unitSize
    svgAttrs      = [ Svg.height_ (ms imgHeight), Svg.width_ (ms imgWidth) ]

viewBoundaries :: V2 Int -> ViewerOptions -> View action
viewBoundaries (V2 w h) opts =
  Svg.g_ [ Svg.class_' "boundaries" ]
    [ viewBoundaryBox (V2 0 $ h + 1) opts
    , viewBoundaryBox (V2 (w-1) $ h + 1) opts
    , Svg.g_ [ Svg.class_' "boundary-source" ] $
      fmap (\y -> viewBoundaryPort Source (V2 0 y) opts) [0..h]
    , Svg.g_ [ Svg.class_' "boundary-target" ] $
      fmap (\y -> viewBoundaryPort Target (V2 (w-1) y) opts) [0..h]
    ]

viewBoundaryBox :: V2 Int -> ViewerOptions -> View action
viewBoundaryBox (V2 x h) opts =
  Svg.g_ [ Svg.class_' "boundary" ]
    [ Svg.rect_
      [ Svg.width_ . ms  $ tileSize opts
      , Svg.height_ . ms $ tileSize opts * h
      , Svg.x_ (ms $ fromIntegral x * tileSize opts)
      , Svg.y_ "0"
      , Svg.stroke_ "transparent"
      , Svg.strokeWidth_ "2"
      , Svg.fill_ "#eee"
      ] []
    ]

viewBoundaryPort :: PortRole -> V2 Int -> ViewerOptions -> View action
viewBoundaryPort role v' opts =
  Svg.polygon_
    [ Svg.points_ (ms $ points >>= pointStr)
    , Svg.stroke_ "#aaa"
    , Svg.fill_ "white"
    ]
  []
  where
    v = ((*z) . fromIntegral) <$> v'
    z = fromIntegral (tileSize opts) :: Double
    c = z / 2.0

    xoff = case role of
      Source -> z
      Target -> 0

    pointStr (V2 x y) = show x ++ "," ++ show y ++ " "
    points = translate <$> [V2 x' c, V2 xoff (0.4*z), V2 xoff (0.6*z)]
      where x' = abs (xoff - 0.25*z) -- cheeky
    translate = (+ v)


viewTile
  :: MatchState Generator
  -> Tile (HyperEdgeId, Generator)
  -> Position
  -> ViewerOptions
  -> View action
viewTile m (TilePseudoNode p    ) v = viewPseudoNode    m p v
viewTile m (TileHyperEdge  (e,g)) v = viewGeneratorWith m e g v

-- | Render a wire in pixel coordinates between two integer grid positions
viewWire
  :: MatchState Generator
  -> Wire Open
  -> Position
  -> Position
  -> ViewerOptions
  -> View action
viewWire m (s,t) x y (ViewerOptions tileSize highlightColor _)
  = wrap $ connectorWith color (f 1 x) (f 0 y) -- dodgy af
  where
    scale   = (* V2 tileSize tileSize)
    stretch = (* V2 2 1)
    shift a = (+ V2 a 0)
    offset  = (+ V2 0 (fromIntegral tileSize / 2))
    f a = offset . fmap fromIntegral . scale . shift a . stretch

    wrap = Svg.g_ [Svg.class_' "wire"] . pure

    sourceHighlight = Bimap.memberR s (_matchStatePortsSource m)
    targetHighlight = Bimap.memberR t (_matchStatePortsTarget m)
    color = case sourceHighlight && targetHighlight of
      True  -> highlightColor
      False -> "black"

-- | Draw a square grid spaced by unitSize pixels over the area specified by
-- the vector.
gridLines :: Double -> V2 Double -> View action
gridLines unitSize (V2 width height) =
  Svg.g_ [] [ Svg.g_ [] horizontal, Svg.g_ [] vertical ]

  where
    horizontal = fmap hline (enumFromThenTo 0 unitSize height)
    vertical   = fmap vline (enumFromThenTo 0 unitSize width)

    hline y = Svg.line_ ([ Svg.x1_ "0", Svg.x2_ (ms width)
                         , Svg.y1_ (ms y), Svg.y2_ (ms y) ] ++ displayOpts) []
    vline x = Svg.line_ ([ Svg.y1_ "0", Svg.y2_ (ms height)
                         , Svg.x1_ (ms x), Svg.x2_ (ms x) ] ++ displayOpts) []

    displayOpts = [ Svg.stroke_ "#cccccc", Svg.strokeDasharray_ "5,5" ]

-- | Draw an invisible SVG rect, one for each grid square, so we can assign a
-- custom 'onClick' to each, and react when user clicks one.
clickableGridSquares :: V2 Int -> Double -> View RawAction
clickableGridSquares size@(V2 w h) unitSize =
  Svg.g_ []
    [ Svg.rect_
      [ Svg.width_ (ms unitSize), Svg.height_ (ms unitSize)
      , Svg.x_ (ms $ fromIntegral x * unitSize)
      , Svg.y_ (ms $ fromIntegral y * unitSize)
      , Svg.stroke_ "transparent"
      , Svg.strokeWidth_ "2"
      , Svg.fill_ "transparent"
      , Svg.onClick (RawClickedTile $ V2 x y)
      ] []
    | x <- [0..w]
    , y <- [0..h]
    ]

-- | View a pseudonode
-- TODO: make these movable! Will require use of the 'PseudoNode' ID.
viewPseudoNode
  :: MatchState Generator
  -> Layout.PseudoNode
  -> V2 Int
  -> ViewerOptions
  -> View action
viewPseudoNode m pn pos (ViewerOptions tileSize highlightColor _) =
  connectorWith color start end
  where
    unitSize = fromIntegral tileSize
    realPos = unitSize *^ V2 2 1 * fmap fromIntegral pos
    start   = realPos + V2 0.0 (unitSize / 2.0) :: V2 Double
    end     = start + V2 unitSize 0.0

    -- TODO: this appears twice, factor into function?
    (Layout.PseudoNode s t _) = pn
    sourceHighlight = Bimap.memberR s (_matchStatePortsSource m)
    targetHighlight = Bimap.memberR t (_matchStatePortsTarget m)
    color = case sourceHighlight && targetHighlight of
      True  -> highlightColor
      False -> "black"

-- TODO:
-- dodgy hack alert: giving (-1) as the HyperEdgeId here, because
-- it won't match in the emptyMatchState anyway.
-- This is kinda rubbish, but preserves the current API.
-- Better fix: pass in whether or not to highlight from outside the function?
viewGenerator
  :: Generator
  -> Position
  -> ViewerOptions
  -> View action
viewGenerator = viewGeneratorWith emptyMatchState (-1)

-- View a Position-annotated generator
-- Generic drawing:
--    * black outline of total area
--    * vertically-centered circle (according to generatorHeight)
--    * Symmetric bezier wires to circle from each port
viewGeneratorWith
  :: MatchState Generator
  -> HyperEdgeId
  -> Generator
  -> Position
  -> ViewerOptions
  -> View action
viewGeneratorWith m e g@(Generator size ports genColor name) pos' opts =
  Svg.g_ [Svg.class_' "generator"]
    [ Svg.rect_
      [ Svg.width_ (ms width), Svg.height_ (ms height)
      , Svg.x_ (ms x), Svg.y_ (ms y)
      , Svg.stroke_ "transparent"
      , Svg.strokeWidth_ "2"
      , Svg.fill_ "transparent"
      ] []
      -- left ports
    , Svg.g_ [] (zipWith drawSourceWire [0..] (snd ports))
      -- right ports
    , Svg.g_ [] (zipWith drawTargetWire [0..] (fst ports))
    , Svg.circle_
      [ Svg.cx_ (ms cx), Svg.cy_ (ms cy), Svg.r_ (ms $ unitSize / 8)
      , Svg.stroke_ genStrokeColor
      , Svg.strokeWidth_ "2"
      , Svg.fill_ genColor
      ] []
    ]
  where
    ViewerOptions tileSize _ _ = opts
    pos = pos' * (V2 2 1)
    unitSize = fromIntegral tileSize
    height = unitSize * fromIntegral (Layout.generatorHeight g) :: Double
    width  = unitSize
    v@(V2 x y) = fmap ((*unitSize) . fromIntegral) pos
    cx = x + width/2.0
    cy = y + height/2.0
    c = V2 cx cy

    genStrokeColor = case Bimap.memberR e (_matchStateEdges m) of
      True  -> highlightColor opts
      False -> "black"

    drawSourceWire i offset =
      let col = if Bimap.memberR (Port (Gen e) i) (_matchStatePortsSource m)
                    then highlightColor opts
                    else "black"
      in  viewGeneratorWire col v c unitSize (Right offset)

    drawTargetWire i offset =
      let color = if Bimap.memberR (Port (Gen e) i) (_matchStatePortsTarget m)
                    then highlightColor opts
                    else "black"
      in  viewGeneratorWire color v c unitSize (Left offset)

-- | View the wires connecting a generator's central shape to its ports
viewGeneratorWire
  :: MS.MisoString
  -> V2 Double -- ^ Top-left coordinate
  -> V2 Double -- ^ Center coordinate
  -> Double    -- ^ Unit (tile) size
  -> Either Int Int -- ^ a port on the ith tile, either Left or Right side
  -> View action
viewGeneratorWire color x cx unitSize port =
  connectorWith color cx (x + V2 px py)
  where
    px = either (const 0) (const unitSize) port
    py = (+ unitSize/2.0) . (*unitSize) . fromIntegral $ either id id port
