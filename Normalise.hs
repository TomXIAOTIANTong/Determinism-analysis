--  File     : Normalise.hs
--  RCS      : $Id$
--  Author   : Peter Schachte
--  Origin   : Fri Jan  6 11:28:23 2012
--  Purpose  : Convert parse tree into AST
--  Copyright: � 2012 Peter Schachte.  All rights reserved.

-- |Support for normalising wybe code as parsed to a simpler form
--  to make compiling easier.
module Normalise (normalise) where

import AST
import Data.Map as Map
import Data.Set as Set
import Data.List as List
import Text.ParserCombinators.Parsec.Pos
import Control.Monad
  
-- |Normalise a list of file items, storing the results in the current module.
normalise :: [Item] -> Compiler ()
normalise items = do
    mapM_ normaliseItem items

-- |Normalise a single file item, storing the result in the current module.
normaliseItem :: Item -> Compiler ()
normaliseItem (TypeDecl vis (TypeProto name params) items pos) = do
    dir <- getDirectory
    parentmod <- getModuleSpec
    enterModule dir (parentmod ++ [name]) (Just params)
    addType name (TypeDef (length params) pos) vis
    normalise items
    mod <- finishModule
    addSubmod name mod pos vis
    return ()
normaliseItem (ModuleDecl vis name items pos) = do
    dir <- getDirectory
    parentmod <- getModuleSpec
    enterModule dir (parentmod ++ [name]) Nothing
    normalise items
    mod <- finishModule
    addSubmod name mod pos vis
    return ()
normaliseItem (ImportMods vis imp modspecs pos) = do
    mapM_ (\spec -> addImport spec imp Nothing vis) modspecs
normaliseItem (ImportItems vis imp modspec imports pos) = do
    addImport modspec imp (Just imports) vis
normaliseItem (ResourceDecl vis name typ pos) =
  addResource name (SimpleResource typ pos) vis
normaliseItem (FuncDecl vis (FnProto name params) resulttype result pos) =
  normaliseItem $
  ProcDecl 
  vis
  (ProcProto name $ params ++ 
   [Param "$" resulttype ParamOut])
  [Unplaced $
   ProcCall "=" [Unplaced $ Var "$" ParamOut, result]]
  pos
normaliseItem (ProcDecl vis proto@(ProcProto name params) stmts pos) = do
  stmts' <- normaliseStmts stmts
  addProc name (primProto proto) [stmts'] pos vis
normaliseItem (CtorDecl vis proto pos) = do
    modspec <- getModuleSpec
    Just modparams <- getModuleParams
    addCtor (last modspec) modparams proto
normaliseItem (StmtDecl stmt pos) = do
  stmts <- normaliseStmts' stmt [] pos
  oldproc <- lookupProc ""
  case oldproc of
    Nothing -> 
      addProc "" (PrimProto "" []) [stmts] Nothing Private
    Just [ProcDef _ proto [stmts'] pos'] ->
      replaceProc "" 0 proto [(stmts' ++ stmts)] pos' Private

-- |Add a contructor for the specified type.
addCtor :: Ident -> [Ident] -> FnProto -> Compiler ()
addCtor typeName typeParams (FnProto ctorName params) = do
    let typespec = TypeSpec typeName $ List.map (\n->TypeSpec n []) typeParams
    normaliseItem (FuncDecl Public (FnProto ctorName params)
                   typespec
                   (List.foldr
                    (\(Param var _ dir) struct ->
                      (Unplaced $ Fncall 
                       ("update$"++var) 
                       [Unplaced $ Var var dir,struct]))
                    (Unplaced $ Fncall "$alloc" [Unplaced $ 
                                                 Var ctorName ParamIn])
                    $ List.reverse params) 
                   Nothing)
    mapM_ (addGetterSetter typespec ctorName) params

-- |Add a getter and setter for the specified type.
addGetterSetter :: TypeSpec -> Ident -> Param -> Compiler ()
addGetterSetter rectype ctorName (Param field fieldtype _) = do
    ctorVar <- inVar ctorName
    recVar <- inVar "$rec"
    inOutRec <- inOutVar "$rec"
    fieldOutVar <- outVar "$field"
    fieldInVar <- inVar "$field"
    addProc field 
      (PrimProto field [PrimParam "$rec" rectype FlowIn Ordinary,
                        PrimParam "$field" fieldtype FlowOut Implicit])
      [[Unplaced $ PrimForeign "" "access" Nothing 
       (ctorVar ++ recVar ++ fieldOutVar)]]
      Nothing Public
    addProc field 
      (PrimProto field [PrimParam "$rec" rectype FlowIn FirstHalf,
                        PrimParam "$rec" rectype FlowOut SecondHalf,
                        PrimParam "$field" fieldtype FlowIn Ordinary])
      [[Unplaced $ PrimForeign "" "mutate" Nothing 
       (ctorVar ++ inOutRec ++ fieldInVar)]]
      Nothing Public

-- |Normalise the specified statements to primitive statements.
normaliseStmts :: [Placed Stmt] -> Compiler [Placed Prim]
normaliseStmts [] = return []
normaliseStmts (stmt:stmts) =
    case stmt of
        Placed stmt' pos -> normaliseStmts' stmt' stmts $ Just pos
        Unplaced stmt'   -> normaliseStmts' stmt' stmts Nothing

-- |Normalise the specified statement, plus the list of following statements, 
--  to a list of primitive statements.
normaliseStmts' :: Stmt -> [Placed Stmt] -> Maybe SourcePos -> Compiler [Placed Prim]
normaliseStmts' (ProcCall name args) stmts pos = do
  (args',pre,post) <- normaliseArgs args
  back <- normaliseStmts stmts
  return $ pre ++ [maybePlace (PrimCall name Nothing args') pos] ++ post ++ back
normaliseStmts' (ForeignCall lang name args) stmts pos = do
  (args',pre,post) <- normaliseArgs args
  back <- normaliseStmts stmts
  return $ pre ++ [maybePlace (PrimForeign lang name Nothing args') pos] ++ post ++ back
normaliseStmts' (Cond exp thn els) stmts pos = do
  (exp',condstmts) <- normaliseOuterExp exp []
  thn' <- normaliseStmts thn
  els' <- normaliseStmts els
  condproc <- genProcName
  confluence <- genProcName
  let continuation = if List.null stmts then [] 
                     else [Unplaced $ PrimCall confluence Nothing []]
  thenGuard <- makeGuard exp' 1 pos
  elseGuard <- makeGuard exp' 0 pos
  let thn'' = condstmts ++ thenGuard ++ thn' ++ continuation
  let els'' = condstmts ++ elseGuard ++ els' ++ continuation
  addProc condproc (PrimProto condproc []) [thn'',els''] Nothing Private
  stmts' <- normaliseStmts stmts
  if List.null stmts then 
      return () 
    else 
      addProc confluence (PrimProto confluence []) [stmts'] Nothing Private
  return $ condstmts ++ [Unplaced $ PrimCall condproc Nothing []]
normaliseStmts' (Loop loop) stmts pos = do
  (init,body,update) <- normaliseLoopStmts loop
  back <- normaliseStmts stmts
  return $ init ++ [maybePlace (PrimLoop $ body++update) pos] ++ back
normaliseStmts' Nop stmts pos = normaliseStmts stmts

-- |Normalise the specified loop statements to primitive statements.
normaliseLoopStmts :: [Placed LoopStmt] -> 
                      Compiler ([Placed Prim],[Placed Prim],[Placed Prim])
normaliseLoopStmts [] = return ([],[],[])
normaliseLoopStmts (stmt:stmts) = do
  (backinit,backbody,backupdate) <- normaliseLoopStmts stmts
  (frontinit,frontbody,frontupdate) <- case stmt of
    Placed stmt' pos -> normaliseLoopStmt stmt' $ Just pos
    Unplaced stmt'   -> normaliseLoopStmt stmt' Nothing
  return $ (frontinit ++ backinit, 
            frontbody ++ backbody,
            frontupdate ++ backupdate)

-- |Normalise a single loop statement to three list of primitive statements:
--  statements to execute before, during, and afte the loop.p
normaliseLoopStmt :: LoopStmt -> Maybe SourcePos -> 
                     Compiler ([Placed Prim],[Placed Prim],[Placed Prim])
normaliseLoopStmt (For gen) pos = normaliseGenerator gen pos
normaliseLoopStmt (BreakIf exp) pos = do
  (exp',stmts) <- normaliseOuterExp exp []
  condVarName <- freshVar
  condAssign <- assign condVarName exp'
  condExp <- getVar condVarName
  return ([],stmts ++ [condAssign, maybePlace (PrimBreakIf condExp) pos],[])
normaliseLoopStmt (NextIf exp) pos = do
  (exp',stmts) <- normaliseOuterExp exp []
  condVarName <- freshVar
  condAssign <- assign condVarName exp'
  condExp <- getVar condVarName
  return ([],stmts ++ [condAssign, maybePlace (PrimNextIf condExp) pos],[])
normaliseLoopStmt (NormalStmt stmt) pos = do
  stmts <- normaliseStmts' (content stmt) [] pos
  return ([],stmts,[])


-- |Normalise a loop generator to three list of primitive statements:
--  statements to execute before, during, and afte the loop.p
normaliseGenerator :: Generator -> Maybe SourcePos ->
                      Compiler ([Placed Prim],[Placed Prim],[Placed Prim])
normaliseGenerator (In var exp) pos = do
  (arg,init) <- normaliseOuterExp exp []
  stateVar <- freshVar
  testVarName <- freshVar
  asn <- assign stateVar arg
  stateArg <- inOutVar stateVar
  varArg <- inOutVar var
  testArg <- outVar testVarName
  testVar <- getVar testVarName
  let update = procCall "next" (stateArg ++ varArg ++ testArg)
  return (init++[asn,update],
          [update],[Unplaced $ PrimBreakIf testVar])
normaliseGenerator (InRange var exp updateOp inc limit) pos = do
  (arg,init1) <- normaliseOuterExp exp []
  (incArg,init2) <- normaliseOuterExp inc []
  varIn <- inVar var
  varOut <- outVar var
  let update = [procCall updateOp (varIn ++ [incArg] ++ varOut)]
  asn <- assign var arg
  (init,test) <- case limit of
    Nothing -> return (init1++init2,[])
    Just (comp,limit') -> do
      testVarName <- freshVar
      testArg <- outVar testVarName
      testVar <- getVar testVarName
      (limitArg,init3) <- normaliseOuterExp limit' []
      varArg <- inVar var
      return (init1++init2++init3,
              [procCall comp (varArg ++ [limitArg] ++ testArg),
               Unplaced $ PrimBreakIf testVar])
  return (init++[asn],test,update)


-- |Normalise a list of expressions as proc call arguments to a list of 
--  primitive arguments, a list of statements to execute before the 
--  call to bind those arguments, and a list of statements to execute 
--  after the call to store the results appropriately.
normaliseArgs :: [Placed Exp] -> Compiler ([PrimArg],[Placed Prim],[Placed Prim])
normaliseArgs [] = return ([],[],[])
normaliseArgs (pexp:args) = do
  let pos = place pexp
  (arg,_,pre,post) <- normaliseExp (content pexp) (place pexp) ParamIn []
  (args',pres,posts) <- normaliseArgs args
  return (arg ++ args', pre ++ pres, post ++ posts)


-- |Normalise a single read-only expression to a primitve argument 
--  and a list of primitive statements to bind that argument.
normaliseOuterExp :: Placed Exp -> [Placed Prim] -> 
                     Compiler (PrimArg,[Placed Prim])
normaliseOuterExp exp stmts = do
    ([arg],_,pre,post) <- normaliseExp (content exp) (place exp) ParamIn stmts
    return (arg,pre++post)


-- |Normalise a single expressions with specified flow direction to
--  primitive argument(s), a list of statements to execute
--  to bind it, and a list of statements to execute 
--  after the call to store the result appropriately.
normaliseExp :: Exp -> Maybe SourcePos -> FlowDirection -> [Placed Prim] ->
                 Compiler ([PrimArg],FlowDirection,[Placed Prim],[Placed Prim])
normaliseExp (IntValue a) pos dir rest = do
  mustBeIn dir pos
  return ([ArgInt a], ParamIn, [], rest)
normaliseExp (FloatValue a) pos dir rest = do
  mustBeIn dir pos
  return ([ArgFloat a], ParamIn, [], rest)
normaliseExp (StringValue a) pos dir rest = do
  mustBeIn dir pos
  return ([ArgString a], ParamIn, [], rest)
normaliseExp (CharValue a) pos dir rest = do
  mustBeIn dir pos
  return ([ArgChar a], ParamIn, [], rest)
normaliseExp (Var name dir) pos _ rest = do
  args <- flowVar name dir -- XXX shouldn't ignore list tail
  return (args, dir, [], rest)
normaliseExp (Where stmts exp) pos dir rest = do
  mustBeIn dir pos
  stmts1 <- normaliseStmts stmts
  (exp',stmts2) <- normaliseOuterExp exp []
  return ([exp'], ParamIn, stmts1++stmts2, rest)
normaliseExp (CondExp cond thn els) pos dir rest = do
  mustBeIn dir pos
  (cond',stmtscond) <- normaliseOuterExp cond []
  (thn',stmtsthn) <- normaliseOuterExp thn []
  resultVar <- freshVar
  thnAssign <- assign resultVar thn'
  (els',stmtsels) <- normaliseOuterExp els []
  elsAssign <- assign resultVar els'
  result <- inVar resultVar
  prims <- makeCond cond' 
           [stmtsthn++[thnAssign], stmtsels++[elsAssign]]
           rest
           pos
  return (result, ParamIn, stmtscond++prims, [])
normaliseExp (Fncall name exps) pos dir rest = do
  mustBeIn dir pos
  (exps',dir',pre,post) <- normalisePlacedExps exps rest
  let inexps = List.filter argIsInput exps'
  resultName <- freshVar
  let dir'' = dir `flowJoin` dir'
  pre' <- if flowsIn dir'' 
          then do
              resultOut <- outVar resultName
              let args = inexps++resultOut
              let instr = maybePlace (PrimCall name Nothing args) pos
              return $ pre ++ [instr]
          else return pre
  post' <- if flowsOut dir''
           then do
               resultIn <- inVar resultName
               let args = exps'++resultIn
               let instr = maybePlace (PrimCall name Nothing args) pos
               return $ instr:post
           else return $ post
  result <- flowVar resultName dir'' -- XXX shouldn't ignore list tail
  return (result, dir'', pre', post')
normaliseExp (ForeignFn lang name exps) pos dir rest = do
  mustBeIn dir pos
  (exps',_,pre,post) <- normalisePlacedExps exps rest
  resultName <- freshVar
  resultIn <- inVar resultName
  resultOut <- outVar resultName
  let args = exps'++resultOut
  let pre' = pre ++ [maybePlace (PrimForeign lang name Nothing args) pos]
  return (resultIn, ParamIn, pre', post)

-- |Normalise a list of expressions as function call arguments to a list of 
--  primitive arguments; a flow direction summarising whether there 
--  are any inputs and any outputs among the function arguments;
--  a list of statements to execute before the 
--  call to bind those arguments, and a list of statements to execute 
--  after the call to store the results appropriately.
normalisePlacedExps :: [Placed Exp] -> [Placed Prim] ->
                      Compiler ([PrimArg],FlowDirection,
                                [Placed Prim],[Placed Prim])
normalisePlacedExps [] rest = return ([],NoFlow,[],rest)
normalisePlacedExps (exp:exps) rest = do
  (args',flow',pres,posts) <- normalisePlacedExps exps rest
  (exp',flow,pre,post) <- normaliseExp (content exp) (place exp) ParamIn []
  return  (exp' ++ args', flow `flowJoin` flow', pre ++ pres, post ++ posts)

-- | Report an error if the specified flow direction has output.
mustBeIn :: FlowDirection -> Maybe SourcePos -> Compiler ()
mustBeIn flow pos =
    when (flowsOut flow)
    $ message Error "Flow error:  invalid output argument" pos

-- |Does the specified flow direction flow in?
flowsIn :: FlowDirection -> Bool
flowsIn NoFlow     = False
flowsIn ParamIn    = True
flowsIn ParamOut   = False
flowsIn ParamInOut = True

-- |Does the specified flow direction flow out?
flowsOut :: FlowDirection -> Bool
flowsOut NoFlow     = False
flowsOut ParamIn = False
flowsOut ParamOut = True
flowsOut ParamInOut = True

-- |Transform the specified primitive argument to an input parameter.
argIsInput :: PrimArg -> Bool
argIsInput (ArgVar var dir _) = dir == FlowIn
argIsInput _ = True

-- |Generate a primitive assignment statement.
assign :: VarName -> PrimArg -> Compiler (Placed Prim)
assign var val = do
  lval <- outVar var
  return $ procCall "=" (lval ++ [val])

-- |Generate a primitive proc call
procCall :: ProcName -> [PrimArg] -> Placed Prim
procCall proc args = Unplaced $ PrimCall proc Nothing args

-- |Generate a primitive conditional.
makeCond :: PrimArg -> [[Placed Prim]] -> [Placed Prim] -> Maybe SourcePos -> 
            Compiler [Placed Prim]
makeCond cond branches rest pos = do
  case cond of
    ArgVar name FlowIn _ -> do
      result <- freshVar
      return $ [maybePlace (PrimCond name branches) pos] ++ rest
    ArgInt n ->
      if n >= 0 && n <= fromIntegral (length branches) then
        return $ (branches !! (fromInteger n)) ++ rest
      else
        return $ head branches ++ rest
    _ -> do
      message Error "Can't use a non-integer type as a Boolean" pos
      return $ head branches ++ rest -- XXX has the right type, but probably not good


-- |Generate a primitive conditional.
makeGuard :: PrimArg -> Integer -> Maybe SourcePos -> Compiler [Placed Prim]
makeGuard arg val pos = do
  case arg of
    ArgVar name FlowIn _ -> do
      return [maybePlace (PrimGuard name val) pos]
    ArgInt n ->
      if n == val then
        return []
      else
        return [maybePlace PrimFail pos]
    _ -> do
      message Error "Can't use a non-integer type as a Boolean" pos
      return [maybePlace PrimFail pos]


-- |Join on the lattice of flow directions (NoFlow is bottom, 
--  ParamInOut is top, and the others are incomparable in between).
flowJoin :: FlowDirection -> FlowDirection -> FlowDirection
flowJoin NoFlow     x          = x
flowJoin x          NoFlow     = x
flowJoin ParamInOut _          = ParamInOut
flowJoin _          ParamInOut = ParamInOut
flowJoin ParamIn    ParamOut   = ParamInOut
flowJoin ParamIn    ParamIn    = ParamIn
flowJoin ParamOut   ParamOut   = ParamOut
flowJoin ParamOut   ParamIn    = ParamInOut
