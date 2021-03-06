
{-# LANGUAGE FlexibleContexts #-}

module LALRAutomaton (module LALRAutomaton) where

import Syntax
import Utility

import qualified Data.Map as Map
import qualified Data.Set as Set

import Control.Monad         (forM_, mzero, (<=<), when, unless, foldM)
import Control.Monad.Writer  (MonadWriter(), tell, execWriter)
import Data.List             (nub, sort)
import Data.Maybe            (mapMaybe)
import Data.Monoid           (Endo(), (<>))

-------------------------------------------------------------------------------

data LRAutomaton = LRAutomaton {
  lrAutomatonStart      :: LRNode,
  lrAutomatonEdgesTable :: Map.Map LRNode (Map.Map Symbol LRNode)
} deriving (Eq)

data LRNode = LRNode { getLRNode :: Map.Map LRItem (Set.Set Terminal) }
  deriving (Eq, Ord)

data LRItem = LRItem { lrItemRule :: Rule,
                       lrItemRest :: [Symbol] }
  deriving (Eq, Ord)

-------------------------------------------------------------------------------

lrAutomatonEdges :: LRAutomaton -> LRNode -> [(Symbol, LRNode)]
lrAutomatonEdges automaton node = maybe [] Map.toList (Map.lookup node table)
  where table = lrAutomatonEdgesTable automaton

lrAutomatonNodes :: LRAutomaton -> [LRNode]
lrAutomatonNodes automaton = nub ([start] ++ lhsNodes ++ rhsNodes)
  where start = lrAutomatonStart automaton
        lhsNodes = Map.keys (lrAutomatonEdgesTable automaton)
        rhsNodes = (Map.elems <=< Map.elems) (lrAutomatonEdgesTable automaton)

lrAutomatonNext :: LRAutomaton -> LRNode -> Symbol -> Maybe LRNode
lrAutomatonNext automaton src sym = do
  return (lrAutomatonEdgesTable automaton) >>= Map.lookup src >>= Map.lookup sym

lrAutomatonTerminals :: LRAutomaton -> [Terminal]
lrAutomatonTerminals automaton = do
  symbol <- Map.elems (lrAutomatonEdgesTable automaton) >>= Map.keys
  case symbol of
    TerminalSymbol t -> return t
    _                -> mzero

-------------------------------------------------------------------------------

lrItem :: Rule -> LRItem
lrItem rule = LRItem rule (ruleRhs rule)

lrItemNext :: LRItem -> Maybe (Symbol, LRItem)
lrItemNext item = case lrItemRest item of
  []             -> Nothing
  symbol : rest' -> Just (symbol, LRItem (lrItemRule item) rest')

-------------------------------------------------------------------------------

lrNodeItems :: LRNode -> [(LRItem, Set.Set Terminal)]
lrNodeItems node = Map.toList (getLRNode node)

instance Monoid LRNode where
  mempty  = LRNode Map.empty
  mappend node1 node2 = LRNode (Map.unionWith Set.union (getLRNode node1) (getLRNode node2))

leadingNonTerminals :: LRNode -> [(NonTerminal, [Symbol], Set.Set Terminal)]
leadingNonTerminals node = mapMaybe search (lrNodeItems node)
  where search (item, la) = case lrItemRest item of
          NonTerminalSymbol nt : rest -> Just (nt, rest, la)
          _                           -> Nothing

lrNode :: Syntax -> NullableTable -> FirstSetTable -> LRItem -> Set.Set Terminal -> LRNode
lrNode syntax nullable table item la = complement (LRNode (Map.singleton item la))
  where complement = fixPoint (\node -> node <> grow node)
        grow node = foldMap LRNode $ do
          (nt, rest, la) <- leadingNonTerminals node
          rule <- syntaxRules syntax nt
          return (Map.singleton (lrItem rule) (firstSet syntax nullable table la rest))

initialLRNode :: Syntax -> NullableTable -> FirstSetTable -> LRNode
initialLRNode syntax nullable table = lrNode syntax nullable table start (Set.singleton EndOfInput)
  where start = lrItem (startRule (syntaxStart syntax))

lrTransitions :: Syntax -> NullableTable -> FirstSetTable -> LRNode -> Map.Map Symbol LRNode
lrTransitions syntax nullable table src = Map.fromListWith mappend $ do
  (item, la)      <- lrNodeItems src
  (symbol, item') <- maybe [] return (lrItemNext item)
  return (symbol, lrNode syntax nullable table item' la)

-------------------------------------------------------------------------------

lr1Automaton :: Syntax -> LRAutomaton
lr1Automaton syntax = fixPoint grow seed
  where nullable        = buildNullableTable syntax
        table          = buildFirstSetTable syntax nullable
        seed           = LRAutomaton (initialLRNode syntax nullable table) Map.empty
        grow automaton = LRAutomaton (lrAutomatonStart automaton) $
          Map.fromListWith (Map.unionWith mappend) $
            [(node, lrTransitions syntax nullable table node) |
             node <- lrAutomatonNodes automaton]

lalrAutomaton :: Syntax -> LRAutomaton
lalrAutomaton syntax = mergeLRAutomatonNodes (lr1Automaton syntax)

mergeLRAutomatonNodes :: LRAutomaton -> LRAutomaton
mergeLRAutomatonNodes automaton = LRAutomaton start edges
  where mergeGroups = Map.fromListWith (++) $
          [(Set.fromList (map fst (lrNodeItems node)), [node]) |
           node <- lrAutomatonNodes automaton]
        mergeTable = Map.fromList $
          [(node, mconcat group) | group <- Map.elems mergeGroups, node <- group]
        start = mergeTable Map.! lrAutomatonStart automaton
        edges = Map.mapKeysWith (Map.unionWith assertEq) (mergeTable Map.!) (fmap (fmap (mergeTable Map.!)) (lrAutomatonEdgesTable automaton))

-- (v -> v -> Bool) -> [v] -> [[v]]
-- (Monoid v) => [[v]] -> Map.Map v v

-------------------------------------------------------------------------------

shifts :: LRAutomaton -> [(Terminal, (LRNode, LRNode))]
shifts automaton = sort $ do
  (src, dsts)   <- Map.toList (lrAutomatonEdgesTable automaton)
  (symbol, dst) <- Map.toList dsts
  case symbol of
    TerminalSymbol t -> return (t, (src, dst))
    _                -> mzero

reduces :: LRAutomaton -> Rule -> [([LRNode], [LRNode])]
reduces automaton rule =
  [(path node (ruleRhs rule), path node [NonTerminalSymbol (ruleLhs rule)]) |
   node <- lrAutomatonNodes automaton,
   any (\(item, _) -> item == lrItem rule) (lrNodeItems node)]
  where path = scanl $ \node symbol ->
          lrAutomatonEdgesTable automaton Map.! node Map.! symbol

-- reduces :: LRAutomaton -> Rule -> Terminal -> [([LRNode], [LRNode])]
-- reduces automaton rule t =
--   [(path node (ruleRhs rule), path node [NonTerminalSymbol (ruleLhs rule)]) |
--    node <- lrAutomatonNodes automaton,
--    any (\(item, la) -> item == lrItem rule && Set.member t la) (lrNodeItems node)]
--   where path = scanl $ \node symbol ->
--           lrAutomatonEdgesTable automaton Map.! node Map.! symbol

acceptible :: LRNode -> Bool
acceptible node = or [ruleLhs (lrItemRule item) == StartSymbol &&
                      null (lrItemRest item)
                     | item <- Map.keys (getLRNode node)]

-------------------------------------------------------------------------------

tellLRItem :: (MonadWriter (Endo String) m) => LRItem -> m ()
tellLRItem (LRItem rule rest) = do
  let dones = take (length (ruleRhs rule) - length rest) (ruleRhs rule)
  tells (ruleName rule) >> tells " : "
  tellNonTerminal (ruleLhs rule) >> tells " -> "
  forM_ dones $ \done -> tellSymbol done >> tells " "
  tells "."
  forM_ rest $ \symbol -> tells " " >> tellSymbol symbol

tellLRNode :: (MonadWriter (Endo String) m) => LRNode -> m ()
tellLRNode (LRNode node) = do
  tells "["
  forMWithSep_ (tells "; ") (Map.toList node) $ \(lrItem, la) -> do
    tellLRItem lrItem
    tells " [" >> mapMWithSep_ (tells ", ") tellTerminal la >> tells "]"
  tells "]"

tellLRAutomaton :: (MonadWriter (Endo String) m) => LRAutomaton -> m ()
tellLRAutomaton automaton = do
  tellsLn "automaton {"
  forM_ (Map.toList (lrAutomatonEdgesTable automaton)) $ \(src, dsts) -> do
    tells " * " >> tellLRNode src
    when (src == lrAutomatonStart automaton) (tells "  <-- start")
    tellNewline
    forM_ (Map.toList dsts) $ \(symbol, dst) -> do
      tells "   - " >> tellSymbol symbol >> tells " -> " >> tellLRNode dst >> tellNewline
  tells   "}"

-------------------------------------------------------------------------------

instance Show LRItem where
  showsPrec d lrItem =
    showString "LRItem[" . tolds (tellLRItem lrItem) . showString "]"

instance Show LRNode where
  showsPrec d lrNode = showParen (d > 10) $
    showString "LRNode" . tolds (tellLRNode lrNode)

instance Show LRAutomaton where
  showsPrec d automaton = showParen (d > 0) $
    tolds (tellLRAutomaton automaton)

-------------------------------------------------------------------------------
