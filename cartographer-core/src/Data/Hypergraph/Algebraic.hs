{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
-- | Algebraically construct hypergraphs as monoidal categories.
module Data.Hypergraph.Algebraic
  ( (→)
  , tensor
  , OpenHypergraph(..)
  ) where

import Prelude hiding (id, (.))
import Control.Monad
import Control.Category
import Control.Arrow
import Data.Monoid
import Data.Maybe (catMaybes, isJust)
import Data.List (foldl')
import Data.Reflection

import Data.Hypergraph.Type as Hypergraph

import Data.Map (Map)
import qualified Data.Map as Map

import Data.Bimap (Bimap)
import qualified Data.Bimap as Bimap

instance Ord sig => Semigroup (OpenHypergraph sig) where
  (<>) = tensor

instance Ord sig => Monoid (OpenHypergraph sig) where
  mempty = Hypergraph.empty

tensor
  :: Ord sig
  => OpenHypergraph sig -> OpenHypergraph sig -> OpenHypergraph sig
tensor a b = a
  { connections = foldl' (flip $ uncurry Bimap.insert) (connections a) newWires
  , signatures  = foldl' (flip $ uncurry Map.insert) (signatures a) newEdges
  , nextHyperEdgeId = maxA + maxB
  }
  where
    newEdges = (\(e,s) -> (e + maxA, s)) <$> Map.toList (signatures b)
    newWires = (fixPort *** fixPort) <$> Bimap.toList (connections b)

    maxA = nextHyperEdgeId a
    maxB = nextHyperEdgeId b
    (ai, ao) = hypergraphSize a
    (bi, bo) = hypergraphSize b
    offset   = max 0 (ao - bi)

    {-fixPort :: Reifies a PortRole => Port a Open -> Port a Open-}
    fixPort p@(Port Boundary i) = Port Boundary (i + offset)
      where offset = portRole ai ao p
    fixPort (Port (Gen (e, t)) i) = Port (Gen (e + maxA, t)) i


-- | Sequentially compose two hypergraphs, even when types don\'t match.
-- Wires left dangling as a result of mismatched types will automatically be
-- connected to their corresponding boundary.
--
-- in a → b, if a has more outputs, then b will connect to the *lowermost*
-- outputs of a. If b has more inputs than a has outputs, then a will connect
-- to the *uppermost* inputs of b, e.g.:
--
-- This is "asymmetric" because it means no changes ever have to be made to the
-- "a" graph, which is assumed to be much larger than the "b" graph.
--
--   ┌───┐    ┌───┐           ┌───┐
--   │ A │────│ B │           │ A │─────────
--   └───┘    │   │           │   │     ┌───┐
--   ─────────│   │           │   │──── │ B │
--            └───┘           └───┘     └───┘
--   A has fewer outputs       B has fewer inputs
--
-- see wiki/ALGEBRAIC.md for implementation details
--
-- NOTE: this is just a special case of rewriting, where the match is every
-- wire connected to the RHS boundary, plus a little extra work to make it
-- "affine".
-- It might be better to reimplement this, but I think handling as a special
-- case makes it a bit faster?
(→) :: Ord a => OpenHypergraph a -> OpenHypergraph a -> OpenHypergraph a
a → b = a
  { connections = foldl' (flip $ uncurry Bimap.insert) (connections a) newWires
  , signatures  = foldl' (flip $ uncurry Map.insert) (signatures a) newEdges
  , nextHyperEdgeId = maxA + maxB
  }
  where
    newEdges = (\(e,s) -> (e + maxA, s)) <$> Map.toList (signatures b)
    newWires = rewireB <$> Bimap.toList (connections b)

    maxA = nextHyperEdgeId a
    maxB = nextHyperEdgeId b
    (ai, ao) = hypergraphSize a
    (bi, bo) = hypergraphSize b
    offset   = max 0 (ao - bi)

    {-rewireB :: Wire sig Open -> Wire sig Open-}
    rewireB = onFst reindexLeft . pairUp . (reindexPort *** reindexPort)
      where onFst f (a,b) = (f a, b)

    -- TODO: don't bother looking up if i >= ao.
    {-pairUp :: Wire sig Open -> Wire sig Open-}
    pairUp w@(Port Boundary i, t) =
      case Bimap.lookupR (Port Boundary i) (connections a) of
        Nothing -> w
        Just s' -> (s', t)
    pairUp w = w

    -- OK, good.
    reindexPort (Port Boundary i) = Port Boundary (i + offset)
    reindexPort (Port (Gen (e, t))  i) = Port (Gen (e + maxA, t)) i

    -- NOTE: only called *after* matchBoundaries, so it will only get ports
    -- which will eventually connect to the boundary.
    reindexLeft (Port Boundary i) = Port Boundary (i - ao + ai)
    reindexLeft p = p
