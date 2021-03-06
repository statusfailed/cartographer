{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
-- | The main interface for editing a Hypergraph via a UI.
-- the 'Layout' type includes position and pseudonode information for each
-- hyperedgein the graph, and provides methods for safely making changes to the underlying graph.
--
-- /This module is intended to be imported qualified./
module Cartographer.Layout where

import Data.Function
import qualified Data.Set as Set

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import qualified Data.Bimap as Bimap

import Linear.V2
import qualified Data.List as List
import Data.Maybe (catMaybes)
import Control.Monad (liftM2)

import Data.Hypergraph
  ( Port(..), PortRole(..), Open(..), Source, Target
  , OpenHypergraph, HyperEdgeId(..)
  , MatchState(..)
  , boundaryPorts
  )
import qualified Data.Hypergraph as Hypergraph

import Cartographer.Types.Grid (Grid, Position)
import qualified Cartographer.Types.Grid as Grid

import Data.Reflection

-- TODO: document this class
-- gist: the "geometric" information about a generator, like its height, and
-- where its ports are positioned relative to the top.
class Hypergraph.Signature sig => Generator sig where
  generatorHeight  :: sig -> Int   -- ^ height of the generator
  generatorInputs  :: sig -> [Int] -- ^ port offset of target ports
  generatorOutputs :: sig -> [Int] -- ^ port offset of source ports

instance Generator (Int, Int) where
  generatorHeight  (k,n) = max k n
  generatorInputs  (k,n) = [0..k]
  generatorOutputs (k,n) = [0..n]

newtype Layer = Layer { unLayer :: Int }
  deriving(Eq, Ord, Read, Show, Enum, Num)

-- | A pseudonode is uniquely identified by the two ports it helps connect,
-- and its offset from the source node.
-- Its x-position is exactly the source port's x position plus the offset.
data PseudoNode = PseudoNode (Port Source Open) (Port Target Open) Int
  deriving(Eq, Ord, Read, Show)

-- | Tiles are user-manipulable 1xN shapes laid out on the grid.  A tile is
-- either a 1xN generator (Hyperedge) or a 1x1 Pseudonode (identity)
data Tile a
  = TileHyperEdge a
  | TilePseudoNode PseudoNode
  deriving(Eq, Ord, Read, Show)

isPseudoTile :: Tile a -> Bool
isPseudoTile (TilePseudoNode _) = True
isPseudoTile _ = False

-- | a 'Hypergraph' plus the additional information needed to display it laid
-- out in 2D.
-- NOTE that we
data Layout sig = Layout
  { hypergraph :: OpenHypergraph sig
  -- ^ the underlying hypergraph to be laid out
  , grid       :: Grid (Tile HyperEdgeId) -- previously Grid HyperEdgeId
  -- ^ Position of each HyperEdge in the layout.
  } deriving(Eq, Ord, Show)

-- | The empty layout state. An empty hypergraph, nothing positioned, and no
-- hyperedges yet created.
empty :: Layout sig
empty = Layout
  { hypergraph      = Hypergraph.empty
  , grid            = Grid.empty
  }

-- | Width/Height of the Layout in tiles
-- NOTE: also has to account for number of boundary nodes
dimensions :: Layout sig -> V2 Int
dimensions layout = V2 rx (maximum [ry, bsMax, btMax])
  where
    (V2 rx ry) = (V2 2 0 +) . Grid.dimensions . grid $ layout
    conns = Bimap.toList . Hypergraph.connections . hypergraph $ layout
    toIndex (Port _ i) = i

    maxBoundary xs =
      let ixs = (fmap toIndex . filter Hypergraph.isBoundary) xs
      in  maybe 0 (+1) (safe maximum ixs)

    bsMax = maxBoundary (map fst conns)
    btMax = maxBoundary (map snd conns)

-- | Look up what's at a particular position in the layout.
-- If no generator or boundary was at that position, Nothing is returned.
lookup
  :: Generator sig
  => V2 Int
  -> Layout sig
  -> (Maybe (Port Target Open), Maybe (Port Source Open))
lookup v@(V2 x y) layout
  | x <= 0     = (Nothing, Just (Port Boundary y))
  | x >= w - 1 = (Just (Port Boundary y), Nothing)
  | otherwise =
      case tilesAsList <$> Grid.lookup v' (grid layout) of
        Nothing                    -> (Nothing, Nothing)
        Just (TilePseudoNode _, _) -> (Nothing, Nothing)
        Just (TileHyperEdge _, []) -> (Nothing, Nothing) -- this is really a bug
        Just (TileHyperEdge e, vs) -> offsetToPorts e (tileOffset v vs) layout
  where
    V2 w _ = dimensions layout
    v' = v - V2 1 0 -- lose the left boundary for "Grid" space coordinates.

    tilesAsList (a, s) = (a, Set.toList s)
    tileOffset u us = let (V2 _ dy) = u - minimum us in dy

signature :: HyperEdgeId -> Layout sig -> Maybe sig
signature e = Map.lookup e . Hypergraph.signatures . hypergraph

-- | Calculate the y-coordinate distance of a port from the topmost tile of its
-- generator, or Nothing if it doesn't exist.
-- NOTE: this port geometry stuff kinda sucks. Would be much nicer to have all
-- generators as single 1x1 tiles, and just evenly space wires ...
portOffset
  :: (Reifies a PortRole, Generator sig)
  => Port a Open
  -> Layout sig
  -> Maybe Int
portOffset (Port Boundary i) _ = Just i
portOffset p@(Port (Gen e) i) layout = do
  sig <- signature e layout
  f sig
  where
    -- guard division by zero- note also "mod" check below, which ensures we
    -- dont index past end of array.
    g n x = if n == 0 then Nothing else Just x

    f sig =
      let (ni, no) = Hypergraph.toSize sig
      in  case Hypergraph.toPortRole p of
          -- Source port means OUTPUT of a generator.
          Source -> g no $ (generatorOutputs sig ++ [0..no]) !! (i `mod` no)
          -- Target port means
          Target -> g ni $ (generatorInputs  sig ++ [0..ni]) !! (i `mod` ni)

-- | Given a HyperEdgeId and an offset, what ports does it correspond to?
-- This can be a source port, or target, or both.
offsetToPorts
  :: Generator sig
  => HyperEdgeId
  -> Int
  -> Layout sig
  -> (Maybe (Port Target Open), Maybe (Port Source Open))
offsetToPorts e i layout = case signature e layout of
  Nothing  -> (Nothing, Nothing)
  Just sig ->
    ( Port (Gen e) <$> List.findIndex (==i) (generatorInputs sig)
    , Port (Gen e) <$> List.findIndex (==i) (generatorOutputs sig)
    )


-- | Insert a generator into a specific layer, at a particular offset.
-- If it would overlap with another generator, the generators are shifted down
-- to make space.
--
-- If the generator would increase the size of the grid in the X direction,
-- insert new pseudonodes for every wire.
-- TODO: this is ridiculously inefficient
placeGenerator
  :: Generator sig
  => sig
  -- ^ What kind of generator?
  -> Position
  -- ^ Where to put it in the grid?
  -> Layout sig
  -> (HyperEdgeId, Layout sig)
placeGenerator sig pos l = (edgeId, recomputePseudoNodes l') where
  height = Grid.Height (generatorHeight sig)
  (edgeId, hg) = Hypergraph.addEdge sig (hypergraph l)

  l' = Layout
    { hypergraph = hg
    -- Add new edgeId to hypergraph

    , grid =
        Grid.placeTile (TileHyperEdge edgeId) height pos (grid l)
    -- Finally, placeTile in Grid to update positions.
    }

-- | Recompute 'PseudoNode's for the entire Layout.
-- NOTE: this works by reconnecting every pair of connected ports in the graph,
--       which ensures that all pseudonodes exist.
-- TODO FIXME: this is super slow and hacky! Be a bit more intelligent about
--             which connections to reconnect!
recomputePseudoNodes :: Generator sig => Layout sig -> Layout sig
recomputePseudoNodes l = foldr (uncurry connectPorts) l wires
  where wires = (Bimap.toList . Hypergraph.connections . hypergraph $ l)

-- | connect two hypergraph ports in the layout.
--
-- TODO:
-- If any of the following are true, the connection is not made:
--    * ports are invalid
--    * L(target) <= L(source)
--
-- Additionally, A maximum if L(target) - L(source) - 1 pseudonodes are
-- inserted into the grid.
{-# WARNING connectPorts "partial function" #-}
connectPorts
  :: Generator sig
  => Port Source Open
  -- ^ Source port
  -> Port Target Open
  -- ^ Target port
  -> Layout sig
  -> Layout sig
connectPorts s t layout
  | not (canConnectPorts s t layout) = layout
  | otherwise = layout'
      { hypergraph = Hypergraph.connect s t (hypergraph layout') }
  where
    -- cleanS and cleanT remove any existing pseudonodes that are no longer
    -- needed. TODO: move this into another function? :-)
    cleanS l =
      if Hypergraph.target s (hypergraph l) /= Just t
        then disconnectSource s l
        else l
    cleanT l =
      if Hypergraph.source t (hypergraph l) /= Just s
        then disconnectTarget t l
        else l

    base l = maybe err id (portPosition s l)
      where err = error $ "connectPorts: lookup error " ++ show s

    addPseudo pn@(PseudoNode _ _ i) l = addPseudoNode pn (base l + offset) l
      where offset = V2 i 0

    withPseudos l = foldl (flip addPseudo) l $ connectionPseudoNodes s t l

    layout' = withPseudos . cleanS . cleanT $ layout

-- | We can form a connection s -> t if L(s) < L(t)
canConnectPorts :: Port Source Open -> Port Target Open -> Layout sig -> Bool
canConnectPorts (Port (Gen s) _) (Port (Gen t) _) l = maybe False id $ do
  (V2 xs _) <- positionOf (TileHyperEdge s) l
  (V2 xt _) <- positionOf (TileHyperEdge t) l
  return (xt > xs)
canConnectPorts _ _ _ = True -- boundaries can always be connected.

-------------------------------
-- TODO: NOTE: there is definitely a nicer way to write the below two
-- functions.....
-- Can we make "disconnect" operate on a WIRE instead? (i.e. pair of ports?)
-------------------------------

-- | Remove all the pseudonodes for a given source port
-- if the port has no target, do nothing.
disconnectSource
  :: Port Source Open -> Layout sig -> Layout sig
disconnectSource s l = case Hypergraph.target s (hypergraph l) of
  Just t  ->
    let l' = foldl (flip removePseudoNode) l (connectionPseudoNodes s t l)
    in  l' { hypergraph = Hypergraph.disconnectSource s (hypergraph l') }

  Nothing -> l

-- | Remove all the pseudonodes for a given target port
-- if the port has no source, do nothing.
disconnectTarget
  :: Port Target Open -> Layout sig -> Layout sig
disconnectTarget t l = case Hypergraph.source t (hypergraph l) of
  Just s  ->
    let l' = foldl (flip removePseudoNode) l (connectionPseudoNodes s t l)
    in  l' { hypergraph = Hypergraph.disconnectTarget t (hypergraph l') }
  Nothing -> l

-------------------------------
-- Pseudnodes

-- | Add a pseudonode into the grid.
addPseudoNode :: PseudoNode -> Position -> Layout sig -> Layout sig
addPseudoNode pseudo v layout = layout
  { grid = Grid.placeTile (TilePseudoNode pseudo) 1 v (grid layout) }

-- | Remove a pseudonode from the grid
removePseudoNode :: PseudoNode -> Layout sig -> Layout sig
removePseudoNode pseudo layout = layout
  { grid = Grid.removeTile (TilePseudoNode pseudo) (grid layout) }

--------------------------------------------------------------
-- Utilities / Read-Only functions

-- | A thin wrapper around Grid.positions
-- TODO: replace this interface to return a Map (Tile (Port () Open)) Position ?
-- Then automatically insert Boundary "generators" and shift all non-boundaries
-- right by 1.
-- Computing the Map (Tile HyperEdgeId) Position would just be a simple
-- filter + fmap on this map...
positions :: Layout sig -> Map (Tile HyperEdgeId) Position
positions = Grid.positions . grid

positionOf :: Tile HyperEdgeId -> Layout sig -> Maybe Position
positionOf tile layout = Grid.positionOf tile (grid layout)

-- | Get the position of a port's generator.
-- NOTE: this takes into account the boundaries, so a Source Boundary
-- TODO: FIXME: this actually computes "port offset" using a dumb method of
-- just adding the port index to the y-coordinate. That's not right!
generatorPosition
  :: Reifies a PortRole
  => Port a Open
  -> Layout sig
  -> Maybe Position
generatorPosition p l = case p of
  Port Boundary _ -> return (V2 bx 0) -- bx depends on port role
  Port (Gen e) _  -> fmap (+ V2 1 0) . Grid.positionOf (TileHyperEdge e) $ g
  where
    g       = grid l
    V2 w _  = Grid.dimensions g
    bx      = if Hypergraph.toPortRole p == Source then 0 else w + 1

-- | Position of the boundary filling the same role as this port.  i.e., if "a"
-- is Target, it's the right boundary, and Source -> left.
boundaryPosition :: PortRole -> Int -> Layout sig -> Position
boundaryPosition role i l = V2 bx i
  where
    V2 w _  = Grid.dimensions (grid l)
    bx = if role == Source then 0 else w + 1

-- | Calculate the integer-grid coordinates of a *port*, rather than its
-- generator.
portPosition
  :: (Generator sig, Reifies a PortRole)
  => Port a Open
  -> Layout sig
  -> Maybe Position
portPosition p@(Port Boundary i) l = return (boundaryPosition role i l)
  where role = Hypergraph.toPortRole p
portPosition p@(Port (Gen _) _) l = do
  pos <- generatorPosition p l
  offset <- portOffset p l
  return $ pos + V2 0 offset

-- | Compute which pseudonodes must exist for a given connection
connectionPseudoNodes
  :: Port Source Open -> Port Target Open -> Layout sig -> [PseudoNode]
connectionPseudoNodes source target layout = maybe [] id $ do
  n <- layersBetween source target layout
  return $ fmap (PseudoNode source target) [0..n-1]

-- | Number of layers separating two ports.
-- Returns Nothing if ports are invalid.
layersBetween :: Port Source Open -> Port Target Open -> Layout sig -> Maybe Int
layersBetween s t l
  = getX <$> liftM2 f (generatorPosition t l) (generatorPosition s l)
  where
    getX (V2 x _) = x
    f a b = a - b - 1 -- "between" means layers not occupied by either tile.

-- | Insert a new Layer, corresponding to a new column, at a given position.
insertLayer
  :: Layer -- ^ X coordinate of layer to insert
  -> Int   -- ^ Number of layers to insert
  -> Layout sig
  -> Layout sig
insertLayer x n layout
  = layout { grid = Grid.shiftLayer (unLayer x) n (grid layout) }

-------------------------------
-- Matching & Rewriting helpers

matchLayout
  :: (Hypergraph.Signature sig, Eq sig)
  => Layout sig -> Layout sig -> [MatchState sig]
matchLayout pattern graph = Hypergraph.match (hypergraph pattern) (hypergraph graph)

-- | Automatically lay out a hypergraph by positioning its hyperedges in a way
-- that preserves the layering invariant.
--
-- TODO: pick the y coordinate more carefully?
layout :: Generator sig => OpenHypergraph sig -> Grid (Tile HyperEdgeId)
layout hg =
  foldr (uncurry place) Grid.empty (Map.toList $ Hypergraph.signatures hg)
  where
    -- use layering as the x coordinate.
    m = Map.fromList (Hypergraph.layer hg)
    place e sig = case Map.lookup e m of
      Nothing  -> error $ "layout: " ++ show e
      Just x ->
        let h = Grid.Height (generatorHeight sig)
        in  Grid.placeTile (TileHyperEdge e) h (V2 x 0)

-- | Apply a rewrite rule on Layouts.
-- uses 'layout' to redraw the rewritten graph.
rewriteLayout
  :: Generator sig
  => MatchState sig -- ^ a matching of the LHS of a rule in the context
  -> Layout sig     -- ^ the rule\'s RHS
  -> Layout sig     -- ^ the context which the matching took place in
  -> (Layout sig, MatchState sig) -- ^ rewritten context + match for rewrite
rewriteLayout lhsMatch rhs context = (recomputePseudoNodes context', rhsMatch)
  where
    -- first rewrite the hypergraph:
    (hypergraph', rhsMatch) =
      Hypergraph.rewrite lhsMatch (hypergraph rhs) (hypergraph context)

    context' = context
      { hypergraph = hypergraph'
      , grid       = layout hypergraph'
      }

-------------------------------
-- Tidier layouts

-- | Delete layers containing only pseudonodes
removePseudonodeOnlyLayers :: Layout sig -> Layout sig
removePseudonodeOnlyLayers layout = layout
  { grid = foldr Grid.removeLayer (grid layout) (pseudoLayers . grid $ layout)
  }
  where
    layer ((V2 x _), _) = x
    pseudoLayers
      = List.sort -- put in order highest first, so we can remove
      . fmap (layer . head) -- get the coords of those layers
      . filter (all isPseudoTile . fmap snd) -- those where all are pseudos
      . List.groupBy ((==) `on` layer) -- group by layer
      . Grid.occupiedTiles -- tiles, in order

-- | delete a generator from the Layout
deleteGenerator
  :: Generator sig
  => HyperEdgeId -> Layout sig -> Layout sig
deleteGenerator e l@(Layout hg g) = recomputePseudoNodes (Layout hg' g')
  where
    hg' = Hypergraph.deleteEdge e hg
    g'  = Grid.removeTile (TileHyperEdge e) g

-- | Set a hyperedge's position, while maintaining the layering invariant.
-- If necessary, delete wires that break the invariant
-- TODO: bug!?!?!?
move
  :: Generator sig => Tile HyperEdgeId -> Position -> Layout sig -> Layout sig
move t@(TilePseudoNode _) v l = l { grid = grid' } where
  grid' = Grid.moveTile t (v * V2 0 1) (grid l)
move t@(TileHyperEdge e) v l =
  recomputePseudoNodes . removeBackwardsConnections e v . updatePosition e v $ l
  where
    updatePosition e v m =
      m { grid = Grid.moveTile (TileHyperEdge e) v (grid m) }

-- | Given a hyperedge and its position in the grid, remove any connections
-- that violate the layering invariant.
--
-- Again, kinda gross implementation.
removeBackwardsConnections
  :: Generator sig
  => HyperEdgeId
  -> Position
  -> Layout sig
  -> Layout sig
removeBackwardsConnections e (V2 x _) l
  = foldr disconnectSource l (fmap fst $ os ++ is)
  where
    os = filter (invalid (x>=) . snd) $ Hypergraph.outputWires (hypergraph l) e
    is = filter (invalid (x<=) . fst) $ Hypergraph.inputWires  (hypergraph l) e

    -- whether a wire is now invalid depends on its geometry.
    invalid _ (Port Boundary _) = False
    invalid f (Port (Gen e) _)  = maybe True f $ do
      (V2 x' _) <- Grid.positionOf (TileHyperEdge e) (grid l)
      return x'

-------------------------------
-- Utilities

safe :: ([a] -> a) -> [a] -> Maybe a
safe _ [] = Nothing
safe f xs = Just (f xs)
