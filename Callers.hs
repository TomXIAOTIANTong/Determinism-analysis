--  File     : Callers.hs
--  RCS      : $Id$
--  Author   : Peter Schachte
--  Origin   : Thu Mar 26 14:25:37 AEDT 2015
--  Purpose  : Find all callers for each proc and count static calls per caller
--  Copyright: (c) 2015 Peter Schachte.  All rights reserved.
--

module Callers ( collectCallers ) where

import           AST
import           Data.List  as List
import           Data.Map   as Map
import           Data.Maybe


collectCallers :: ModSpec -> Compiler ()
collectCallers mod = do
  reenterModule mod
  procs <- getModuleImplementationField modProcs
  let procs' = Map.foldrWithKey (noteProcCallers mod) procs procs
  updateImplementation (\imp -> imp {modProcs = procs'})
  reexitModule
  return ()


noteProcCallers :: ModSpec -> ProcName -> [ProcDef] ->
                       Map Ident [ProcDef] -> Map Ident [ProcDef]
noteProcCallers mod name defs procs =
  List.foldr (\(def,n) ->
               noteImplnCallers (ProcSpec mod name n) (procImpln def))
  procs $ zip defs [0..]

noteImplnCallers :: ProcSpec -> ProcImpln ->
                       Map Ident [ProcDef] -> Map Ident [ProcDef]
noteImplnCallers _ (ProcDefSrc _) _ =
  shouldnt "scanning unprocessed code for calls"
noteImplnCallers caller (ProcDefPrim _ body) procs =
  let callers = foldBodyDistrib (noteCall caller)
                Map.empty mergeCallers mergeCallers
                body
  in  registerCallers caller callers procs

-- |Compute for each proc a total count of calls and determine if it
-- should be a subproc of another proc, and if so, which one.
type CallRec = Map ProcSpec Int


noteCall :: ProcSpec -> Bool -> Prim -> CallRec -> CallRec
noteCall caller final (PrimCall spec _) rec =
  Map.alter (Just . maybe 1 (1+)) spec rec
noteCall caller final (PrimTest _) rec = rec
noteCall caller final (PrimForeign _ _ _ _) rec = rec


mergeCallers :: CallRec -> CallRec -> CallRec
mergeCallers rec1 rec2 = Map.unionWith (\n1 n2 -> n1+n2) rec1 rec2

registerCallers :: ProcSpec -> CallRec -> Map Ident [ProcDef]
                   -> Map Ident [ProcDef]
registerCallers caller callRec procs =
  List.foldr (\(callee,count) ps ->
               Map.adjust (adjustNth (noteCalls caller count)
                           (procSpecID callee))
               (procSpecName callee) ps)
  procs
  $ Map.assocs callRec


noteCalls :: ProcSpec -> Int -> ProcDef -> ProcDef
noteCalls caller count procdef =
  procdef { procCallers = Map.alter (Just . (+count) . fromMaybe 0) caller
            $ procCallers procdef}


-- Apply a function to the nth element of a list, leaving the rest untouched.
adjustNth :: (a -> a) -> Int -> [a] -> [a]
adjustNth _ _ [] = error "adjustNth refers beyond list end"
adjustNth fn 0 (e:es) = fn e:es
adjustNth fn n (e:es)
  | n > 0 = e : adjustNth fn (n-1) es
  | True  = error "adjustNth with negative n"
