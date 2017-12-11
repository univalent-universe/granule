{-# LANGUAGE FlexibleInstances, ScopedTypeVariables, FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Checker.Checker where

import Syntax.Expr
import Syntax.Pretty
import Checker.Coeffects
import Checker.Constraints
import Checker.Kinds
import Checker.Monad
import Checker.Patterns
import Checker.Predicates
import Checker.Primitives
import Checker.Types
import Context
import Prelude hiding (pred, print)

import Data.List
import Data.Maybe
import Control.Monad.State.Strict
import Control.Monad.Reader.Class
import Control.Monad.Trans.Maybe
import Data.SBV hiding (kindOf)

-- Checking (top-level)
check :: [Def]        -- List of definitions
      -> Bool         -- Debugging flag
      -> [(Id, Id)]   -- Name map
      -> IO (Either String Bool)
check defs dbg nameMap = do
    -- Get the types of all definitions (assume that they are correct for
    -- the purposes of (mutually)recursive calls).

    -- Kind check all the type signatures
    let checkKinds = mapM (\(Def s _ _ _ tys) -> kindCheck s tys) defs

    -- Build a computation which checks all the defs (in order)...
    let defCtxt = map (\(Def _ var _ _ tys) -> (var, tys)) defs
    let checkedDefs = do
          status <- runMaybeT checkKinds
          case status of
            Nothing -> return [Nothing]
            Just _  -> -- Now check the definition
               mapM (checkDef dbg defCtxt) defs

    -- ... and evaluate the computation with initial state
    results <- evalChecker initState nameMap checkedDefs

    -- If all definitions type checked, then the whole file type checkers
    if all isJust results
      then return . Right $ True
      else return . Left  $ ""

checkDef :: Bool            -- turn on debgging
        -> Ctxt TypeScheme  -- context of top-level definitions
        -> Def              -- definition
        -> Checker (Maybe (Ctxt Assumption))
checkDef dbg defCtxt (Def s defName expr pats (Forall _ foralls ty)) = do
    ctxt <- runMaybeT $ do
      modify (\st -> st { ckctxt = map (\(n, c) -> (n, (c, ForallQ))) foralls})

      ctxt <- case (ty, pats) of
        (FunTy _ _, ps@(_:_)) -> do

          -- Type the pattern matching
          (localGam, ty') <- ctxtFromTypedPatterns dbg s ty ps
          -- Check the body in the context given by the pattern matching
          (localGam', _) <- checkExpr dbg defCtxt localGam Positive True ty' expr
          -- Check that the outgoing context is a subgrading of the incoming
          leqCtxt s localGam' localGam

          -- Check linear use
          case remainingUndischarged localGam localGam' of
                [] -> return localGam'
                xs -> do
                   nameMap  <- ask
                   illLinearity s
                    . intercalate "\n"
                    . map (unusedVariable . unrename nameMap . fst) $ xs
        (tau, []) -> checkExpr dbg defCtxt [] Positive True tau expr >>= (return . fst)
        _         -> illTyped s "Expecting a function type"

      -- Use an SMT solver to solve the generated constraints
      checkerState <- get
      let pred = predicate checkerState
      let predStack = predicateStack checkerState
      dbgMsg dbg $ "Solver prediate is: " ++ pretty (Conj $ pred : predStack)
      solved <- solveConstraints (Conj $ pred : predStack) s defName
      if solved
        then return ctxt
        else illTyped s "Constraints violated"

    -- Erase the solver predicate between definitions
    modify (\st -> st { predicate = Conj [], predicateStack = [], ckctxt = [], cVarCtxt = [] })
    return ctxt

data Polarity = Positive | Negative deriving Show


flipPol :: Polarity -> Polarity
flipPol Positive = Negative
flipPol Negative = Positive

-- Type check an expression

--  `checkExpr dbg defs gam t expr` computes `Just delta`
--  if the expression type checks to `t` in context `gam`:
--  where `delta` gives the post-computation context for expr
--  (which explains the exact coeffect demands)
--  or `Nothing` if the typing does not match.

checkExpr :: Bool             -- turn on debgging
          -> Ctxt TypeScheme   -- context of top-level definitions
          -> Ctxt Assumption   -- local typing context
          -> Polarity         -- polarity of <= constraints
          -> Bool             -- whether we are top-level or not
          -> Type             -- type
          -> Expr             -- expression
          -> MaybeT Checker (Ctxt Assumption, Ctxt Type)

-- Checking of constants

checkExpr _ _ _ _ _ (TyCon "Int") (Val _ (NumInt _)) = return ([], [])
  -- Automatically upcast integers to floats
checkExpr _ _ _ _ _ (TyCon "Float") (Val _ (NumInt _)) = return ([], [])
checkExpr _ _ _ _ _ (TyCon "Float") (Val _ (NumFloat _)) = return ([], [])

checkExpr dbg defs gam pol _ (FunTy sig tau) (Val s (Abs x t e)) = do
  -- If an explicit signature on the lambda was given, then check
  -- it confirms with the type being checked here
  (tau', subst1) <- case t of
    Nothing -> return (tau, [])
    Just t' -> do
      (eqT, unifiedType, subst) <- equalTypes dbg s sig t'
      unless eqT (illTyped s $ pretty t' ++ " not equal to " ++ pretty t')
      return (tau, subst)

  -- Extend the context with the variable 'x' and its type
  gamE <- extCtxt s gam x (Linear sig)
  -- Check the body in the extended context
  (gam', subst2) <- checkExpr dbg defs gamE pol False tau' e
  -- Linearity check, variables must be used exactly once
  case lookup x gam' of
    Nothing -> do
      nameMap <- ask
      illLinearity s $ unusedVariable (unrename nameMap x)
    Just _  -> return (eraseVar gam' x, subst1 ++ subst2)

-- Application special case for built-in 'scale'
checkExpr dbg defs gam pol topLevel tau
          (App s (App _ (Val _ (Var "scale")) (Val _ (NumFloat x))) e) = do
    equalTypes dbg s (TyCon "Float") tau
    checkExpr dbg defs gam pol topLevel (Box (CFloat (toRational x)) (TyCon "Float")) e

-- Application
checkExpr dbg defs gam pol topLevel tau (App s e1 e2) = do
    (argTy, gam2) <- synthExpr dbg defs gam pol e2
    (gam1, subst) <- checkExpr dbg defs gam (flipPol pol) topLevel (FunTy argTy tau) e1
    gam' <- ctxPlus s gam1 gam2
    return (gam', subst)

{-

[G] |- e : t
 ---------------------
[G]*r |- [e] : []_r t

-}

-- Promotion
checkExpr dbg defs gam pol _ (Box demand tau) (Val s (Promote e)) = do
  gamF    <- discToFreshVarsIn s (freeVars e) gam demand
  (gam', subst) <- checkExpr dbg defs gamF pol False tau e
  let gam'' = multAll (freeVars e) demand gam'

  case pol of
      Positive -> leqCtxt s gam'' gam
      Negative -> leqCtxt s gam gam''
  return (gam'', subst)

checkExpr dbg defs gam pol _ tau (Case s guardExpr cases) = do
  -- Synthesise the type of the guardExpr
  (ty, guardGam) <- synthExpr dbg defs gam pol guardExpr
  -- then synthesise the types of the branches
  sharedCtxt <- freshVarsIn s (concatMap freeVars (map snd cases)) gam
  sharedCtxt <- return $ filter isNonLinearAssumption sharedCtxt


  branchCtxtsAndSubst <-
    forM cases $ \(pati, ei) -> do
      -- Build the binding context for the branch pattern
      newConjunct
      (localGam, eVars, subst) <- ctxtFromTypedPattern dbg s ty pati
      newConjunct
      let tau' = substType subst tau
      ---
      let gamSpecialised = map (\(v, t) -> (v, substAssumption subst t)) gam
      (localGam', subst') <- checkExpr dbg defs (gamSpecialised ++ localGam) pol False tau' ei
      -- Check linear use in anything Linear
      nameMap  <- ask
      case remainingUndischarged localGam localGam' of
        -- Return the resulting computed context, without any of
        -- the variable bound in the pattern of this branch
        [] -> do
           -- The current local environment should be subsumed by the
           -- shared context
           leqCtxt s (localGam' `subtractCtxt` localGam) sharedCtxt
           --gee' <- ctxPlus s guardGam sharedCtxt
           --leqCtxt s gee' gam
           concludeImplication eVars
           -- The resulting context has the shared part removed
           let branchCtxt = (localGam' `subtractCtxt` localGam) `subtractCtxt` sharedCtxt
           return (branchCtxt, subst')
        xs -> illLinearity s $ intercalate "\n\t" $ map (unusedVariable . unrename nameMap . fst) xs

  -- Find the upper-bound contexts
  let (branchCtxts, substs) = unzip branchCtxtsAndSubst
  nameMap     <- ask
  branchesGam <- fold1M (joinCtxts s nameMap) branchCtxts

  -- Contract the outgoing context of the guard and the branches (joined)
  g <- ctxPlus s branchesGam guardGam
  g' <- ctxPlus s g sharedCtxt
  return (g', concat substs)

-- All other expressions must be checked using synthesis
checkExpr dbg defs gam pol topLevel tau e = do
  (tau', gam') <- synthExpr dbg defs gam pol e
  (tyEq, _, subst) <-
    case pol of
      Positive -> do
        dbgMsg dbg $ "+ Compare for equality " ++ pretty tau' ++ " = " ++ pretty tau
        leqCtxt (getSpan e) gam' gam
        if topLevel
          -- If we are checking a top-level, then don't allow overapproximation
          then equalTypes dbg (getSpan e) tau' tau
          else lEqualTypes dbg (getSpan e) tau' tau

      -- i.e., this check is from a synth
      Negative -> do
        dbgMsg dbg $ "- Compare for equality " ++ pretty tau ++ " = " ++ pretty tau'
        leqCtxt (getSpan e) gam gam'
        if topLevel
          -- If we are checking a top-level, then don't allow overapproximation
          then equalTypes dbg (getSpan e) tau tau'
          else lEqualTypes dbg (getSpan e) tau tau'

  if tyEq
    then return (gam', subst)
    else illTyped (getSpan e)
            $ "Expected '" ++ pretty tau ++ "' but got '" ++ pretty tau' ++ "'"

-- | Synthesise the 'Type' of expressions.
-- See <https://en.wikipedia.org/w/index.php?title=Bidirectional_type_checking&redirect=no>
synthExpr :: Bool           -- ^ Whether in debug mode
          -> Ctxt TypeScheme -- ^ Context of top-level definitions
          -> Ctxt Assumption   -- ^ Local typing context
          -> Polarity       -- ^ Polarity of subgrading
          -> Expr           -- ^ Expression
          -> MaybeT Checker (Type, Ctxt Assumption)

-- Constants (numbers)
synthExpr _ _ _ _ (Val _ (NumInt _))  = return (TyCon "Int", [])
synthExpr _ _ _ _ (Val _ (NumFloat _)) = return (TyCon "Float", [])

-- Polymorphic list constructors
synthExpr _ _ _ _ (Val _ (Constr "Nil" [])) = do
  elementVar <- freshVar "a"
  modify (\st -> st { ckctxt = (elementVar, (KType, InstanceQ)) : ckctxt st })
  return (TyApp (TyApp (TyCon "List") (TyInt 0)) (TyVar elementVar), [])

synthExpr _ _ _ _ (Val s (Constr "Cons" [])) = do
    let kind = CConstr "Nat="
    sizeVarArg <- freshCoeffectVar "n" kind
    sizeVarRes <- freshCoeffectVar "m" kind
    elementVar <- freshVar "a"
    modify (\st -> st { ckctxt = (elementVar, (KType, InstanceQ)) : ckctxt st })
    -- Add a constraint
    -- m ~ n + 1
    addConstraint $ Eq s (CVar sizeVarRes)
                         (CPlus (CNat Discrete 1) (CVar sizeVarArg)) kind
    -- Cons : a -> List n a -> List m a
    return (FunTy
             (TyVar elementVar)
             (FunTy (list elementVar (TyVar sizeVarArg))
                    (list elementVar (TyVar sizeVarRes))),
                    [])
  where
    list elementVar n = TyApp (TyApp (TyCon "List") n) (TyVar elementVar)

-- Nat constructors
synthExpr _ _ _ _ (Val _ (Constr "Z" [])) = do
  return (TyApp (TyCon "N") (TyInt 0), [])

synthExpr _ _ _ _ (Val s (Constr "S" [])) = do
    let kind = CConstr "Nat="
    sizeVarArg <- freshCoeffectVar "n" kind
    sizeVarRes <- freshCoeffectVar "m" kind
    -- Add a constraint
    -- m ~ n + 1
    addConstraint $ Eq s (CVar sizeVarRes)
                         (CPlus (CNat Discrete 1) (CVar sizeVarArg)) kind
    -- S : Nat n -> Nat (n + 1)
    return (FunTy (nat (TyVar sizeVarArg))
                  (nat (TyVar sizeVarRes)), [])
  where
    nat n = TyApp (TyCon "N") n


-- Constructors (only supports nullary constructors)
synthExpr _ _ _ _ (Val s (Constr name [])) = do
  case lookup name dataConstructors of
    Just (Forall _ [] t) -> return (t, [])
    _ -> unknownName s $ "Data constructor " ++ name

-- Case
synthExpr dbg defs gam pol (Case s guardExpr cases) = do
  -- Synthesise the type of the guardExpr
  (ty, guardGam) <- synthExpr dbg defs gam pol guardExpr
  -- then synthesise the types of the branches
  branchTysAndCtxts <-
    forM cases $ \(pati, ei) -> do
      -- Build the binding context for the branch pattern
      newConjunct
      (localGam, eVars, _) <- ctxtFromTypedPattern dbg s ty pati
      newConjunct
      ---
      (tyCase, localGam') <- synthExpr dbg defs (gam ++ localGam) pol ei
      concludeImplication eVars
      -- Check linear use in anything Linear
      nameMap  <- ask
      case remainingUndischarged localGam localGam' of
         -- Return the resulting computed context, without any of
         -- the variable bound in the pattern of this branch
         [] -> return (tyCase, localGam' `subtractCtxt` localGam)
         xs -> illLinearity s $ intercalate "\n"
                              $ map (unusedVariable . unrename nameMap . fst) xs

  let (branchTys, branchCtxts) = unzip branchTysAndCtxts
  let branchTysAndSpans = zip branchTys (map (getSpan . snd) cases)
  -- Finds the upper-bound return type between all branches
  eqTypes <- foldM (\ty2 (ty1, sp) -> joinTypes dbg sp ty1 ty2)
                   (head branchTys)
                   (tail branchTysAndSpans)

  -- Find the upper-bound type on the return contexts
  nameMap     <- ask
  branchesGam <- fold1M (joinCtxts s nameMap) branchCtxts

  -- Contract the outgoing context of the guard and the branches (joined)
  gamNew <- ctxPlus s branchesGam guardGam

  return (eqTypes, gamNew)

-- Diamond cut
synthExpr dbg defs gam pol (LetDiamond s var ty e1 e2) = do
  gam'        <- extCtxt s gam var (Linear ty)
  (tau, gam1) <- synthExpr dbg defs gam' pol e2
  case tau of
    Diamond ef2 tau' -> do
       (sig, gam2) <- synthExpr dbg defs gam pol e1
       case sig of
         Diamond ef1 ty' | ty == ty' -> do
             gamNew <- ctxPlus s gam1 gam2
             return (Diamond (ef1 ++ ef2) tau', gamNew)
         t -> illTyped s $ "Expected '" ++ pretty ty ++ "' but inferred '" ++ pretty t ++ "' in body of let<>"
    t -> illTyped s $ "Expected '" ++ pretty ty ++ "' in subjet of let <-, but inferred '" ++ pretty t ++ "'"

-- Variables
synthExpr dbg defs gam _ (Val s (Var x)) = do
   nameMap <- ask
   -- Try the local context
   case lookup x gam of
     Nothing ->
       -- Try definitions in scope
       case lookup x (defs ++ builtins) of
         Just tyScheme  -> do
           ty' <- freshPolymorphicInstance tyScheme
           return (ty', [])
         -- Couldn't find it
         Nothing  -> unknownName s $ show (unrename nameMap x)
                              ++ (if dbg then
                                  (" { looking for " ++ x
                                  ++ " in context " ++ pretty gam
                                  ++ " or definitions " ++ pretty defs
                                  ++ "}")
                                 else "")
     -- In the local context
     Just (Linear ty)       -> return (ty, [(x, Linear ty)])
     Just (Discharged ty c) -> do
       k <- inferCoeffectType s c
       return (ty, [(x, Discharged ty (COne k))])

-- Specialised application for scale
synthExpr dbg defs gam pol
      (App s (Val _ (Var "scale")) (Val _ (NumFloat r))) = do
  let float = (TyCon "Float")
  return $ (FunTy (Box (CFloat (toRational r)) float) float, [])

-- Application
synthExpr dbg defs gam pol (App s e e') = do
    (fTy, gam1) <- synthExpr dbg defs gam pol e

    case fTy of
      -- Got a function type for the left-hand side of application
      (FunTy sig tau) -> do
         (gam2, subst) <- checkExpr dbg defs gam pol False sig e'
         gamNew <- ctxPlus s gam1 gam2
         return (substType subst tau, gamNew)

      -- Not a function type
      t -> illTyped s $ "Left-hand side of application is not a function"
                   ++ " but has type '" ++ pretty t ++ "'"

-- Promotion
synthExpr dbg defs gam pol (Val s (Promote e)) = do
   dbgMsg dbg $ "Synthing a promotion of " ++ pretty e

   -- Create a fresh kind variable for this coeffect
   vark <- freshVar $ "kprom_" ++ [head (pretty e)]

   -- Create a fresh coeffect variable for the coeffect of the promoted expression
   var <- freshCoeffectVar ("prom_" ++ pretty e) (CPoly vark)

   gamF <- discToFreshVarsIn s (freeVars e) gam (CVar var)

   (t, gam') <- synthExpr dbg defs gamF pol e

   return (Box (CVar var) t, multAll (freeVars e) (CVar var) gam')

-- Letbox
synthExpr dbg defs gam pol (LetBox s var t e1 e2) = do

    -- Create a fresh kind variable for this coeffect
    ckvar <- freshVar ("binderk_" ++ var)
    let kind = CPoly ckvar
    -- Update coeffect-kind context
    cvar <- freshCoeffectVar ("binder_" ++ var) kind

    -- Extend the context with cvar
    gam' <- extCtxt s gam var (Discharged t (CVar cvar))

    (tau, gam2) <- synthExpr dbg defs gam' pol e2

    (demand, t'') <-
      case lookup var gam2 of
        Just (Discharged t' demand) -> do
             (eqT, unifiedType, _) <- equalTypes dbg s t' t
             if eqT then do
                dbgMsg dbg $ "Demand for " ++ var ++ " = " ++ pretty demand
                return (demand, unifiedType)
              else do
                nameMap <- ask
                illTyped s $ "An explicit signature is given "
                         ++ unrename nameMap var
                         ++ " : '" ++ pretty t
                         ++ "' but the actual type was '" ++ pretty t' ++ "'"
        _ -> do
          -- If there is no explicit demand for the variable
          -- then this means it is not used
          -- Therefore c ~ 0
          addConstraint (Eq s (CVar cvar) (CZero kind) kind)
          return (CZero kind, t)

    (gam1, _) <- checkExpr dbg defs gam (flipPol pol) False (Box demand t'') e1
    gamNew <- ctxPlus s gam1 gam2
    return (tau, gamNew)

-- BinOp
synthExpr dbg defs gam pol (Binop s op e1 e2) = do
    (t1, gam1) <- synthExpr dbg defs gam pol e1
    (t2, gam2) <- synthExpr dbg defs gam pol e2
    -- Look through the list of operators (of which there might be
    -- multiple matching operators)
    case lookupMany op binaryOperators of
      [] -> unknownName s $ "Binary operator " ++ op
      ops -> do
        returnType <- selectFirstByType t1 t2 ops
        gamOut <- ctxPlus s gam1 gam2
        return (returnType, gamOut)

  where
    -- No matching type were found (meaning there is a type error)
    selectFirstByType t1 t2 [] =
      illTyped s $ "Could not resolve operator " ++ op ++ " at type: "
         ++ pretty (FunTy t1 (FunTy t2 (TyVar "?")))

    selectFirstByType t1 t2 ((FunTy opt1 (FunTy opt2 resultTy)):ops) = do
      -- Attempt to use this typing
      (result, local) <- localChecking $ do
         (eq1, _, _) <- equalTypes dbg s t1 opt1
         (eq2, _, _) <- equalTypes dbg s t2 opt2
         return (eq1 && eq2)
      -- If successful then return this local computation
      case result of
        Just True -> local >> return resultTy
        _         -> selectFirstByType t1 t2 ops

    selectFirstByType t1 t2 (_:ops) = selectFirstByType t1 t2 ops


-- Abstraction, can only synthesise the types of
-- lambda in Church style (explicit type)
synthExpr dbg defs gam pol (Val s (Abs x (Just sig) e)) = do
  gam' <- extCtxt s gam x (Linear sig)
  (tau, gam'') <- synthExpr dbg defs gam' pol e
  return (FunTy sig tau, gam'')

-- Pair
synthExpr dbg defs gam pol (Val s (Pair e1 e2)) = do
  (t1, gam1) <- synthExpr dbg defs gam pol e1
  (t2, gam2) <- synthExpr dbg defs gam pol e2
  gam' <- ctxPlus s gam1 gam2
  return (PairTy t1 t2, gam')

synthExpr _ _ _ _ e =
  illTyped (getSpan e) "Type cannot be calculated here; try adding more type signatures."


solveConstraints :: Pred -> Span -> String -> MaybeT Checker Bool
solveConstraints pred s defName = do
  -- Get the coeffect kind context and constraints
  checkerState <- get
  let ctxtCk  = ckctxt checkerState
  let ctxtCkVar = cVarCtxt checkerState
  let coeffectVars = justCoeffectTypesConverted ctxtCk
  let coeffectKVars = justCoeffectTypesConvertedVars ctxtCkVar

  let (sbvTheorem, _, unsats) = compileToSBV pred coeffectVars coeffectKVars

  thmRes <- liftIO . prove $ sbvTheorem

  case thmRes of
     -- Tell the user if there was a hard proof error (e.g., if
     -- z3 is not installed/accessible).
     -- TODO: give more information
     ThmResult (ProofError _ msgs) ->
        illTyped nullSpan $ "Prover error:" ++ unlines msgs
     _ -> if modelExists thmRes
           then
             case getModelAssignment thmRes of
               -- Main 'Falsifiable' result
               Right (False, assg :: [ Integer ] ) -> do
                   -- Show any trivial inequalities
                   mapM_ (\c -> illGraded (getSpan c) (pretty . Neg $ c)) unsats
                   -- Show fatal error, with prover result
                   {-
                   negated <- liftIO . sat $ sbvSatTheorem
                   print $ show $ getModelDictionary negated
                   case (getModelAssignment negated) of
                     Right (_, assg :: [Integer]) -> do
                       print $ show assg
                     Left msg -> print $ show msg
                   -}
                   illTyped s $ "Definition '" ++ defName ++ "' is " ++ show thmRes

               Right (True, _) ->
                   illTyped s $ "Definition '" ++ defName ++ "' returned probable model."

               Left str        ->
                   illTyped s $ "Definition '" ++ defName ++ " had a solver fail: " ++ str

           else return True
  where
    justCoeffectTypesConverted = mapMaybe convert
      where
       convert (var, (KConstr constr, q)) =
           case lookup constr typeLevelConstructors of
             Just KCoeffect -> Just (var, (CConstr constr, q))
             _         -> Nothing
       -- TODO: currently all poly variables are treated as kind 'Coeffect'
       -- but this need not be the case, so this can be generalised
       convert (var, (KPoly constr, q)) = Just (var, (CPoly constr, q))
       convert _ = Nothing
    justCoeffectTypesConvertedVars =
       stripQuantifiers . justCoeffectTypesConverted . map (\(var, k) -> (var, (k, ForallQ)))

leqCtxt :: Span -> Ctxt Assumption -> Ctxt Assumption -> MaybeT Checker ()
leqCtxt s ctxt1 ctxt2 = do
    let ctxt  = ctxt1 `intersectCtxts` ctxt2
        ctxt' = ctxt2 `intersectCtxts` ctxt1
    zipWithM_ (leqAssumption s) ctxt ctxt'

{- | Take the least-upper bound of two contexts.
     If one context contains a linear variable that is not present in
    the other, then the resulting context will not have this linear variable -}
joinCtxts :: Span -> [(Id, Id)] -> Ctxt Assumption -> Ctxt Assumption -> MaybeT Checker (Ctxt Assumption)
joinCtxts s _ ctxt1 ctxt2 = do
    -- All the type assumptions from ctxt1 whose variables appear in ctxt2
    -- and weaken all others
    ctxt  <- intersectCtxtsWithWeaken s ctxt1 ctxt2
    -- All the type assumptions from ctxt2 whose variables appear in ctxt1
    -- and weaken all others
    ctxt' <- intersectCtxtsWithWeaken s ctxt2 ctxt1

    -- Make an context with fresh coeffect variables for all
    -- the variables which are in both ctxt1 and ctxt2...
    varCtxt <- freshVarsIn s (map fst ctxt) ctxt

    -- ... and make these fresh coeffects the upper-bound of the coeffects
    -- in ctxt and ctxt'
    zipWithM_ (leqAssumption s) ctxt varCtxt
    zipWithM_ (leqAssumption s) ctxt' varCtxt
    -- Return the common upper-bound context of ctxt1 and ctxt2
    return varCtxt

{- |  intersect contexts and weaken anything not appear in both
        relative to the left context (this is not commutative) -}
intersectCtxtsWithWeaken ::
    Span -> Ctxt Assumption -> Ctxt Assumption -> MaybeT Checker (Ctxt Assumption)
intersectCtxtsWithWeaken s a b = do
   let intersected = intersectCtxts a b
   -- All the things that were not shared
   let remaining   = b `subtractCtxt` intersected
   let leftRemaining = a `subtractCtxt` intersected
   weakenedRemaining <- mapM weaken remaining
   let newCtxt = intersected ++ filter isNonLinearAssumption (weakenedRemaining ++ leftRemaining)
   return . normaliseCtxt $ newCtxt
  where
   isNonLinearAssumption :: (Id, Assumption) -> Bool
   isNonLinearAssumption (_, Discharged _ _) = True
   isNonLinearAssumption _                   = False

   weaken :: (Id, Assumption) -> MaybeT Checker (Id, Assumption)
   weaken (var, Linear t) =
       return (var, Linear t)
   weaken (var, Discharged t c) = do
       kind <- inferCoeffectType s c
       return (var, Discharged t (CZero kind))

remainingUndischarged :: Ctxt Assumption -> Ctxt Assumption -> Ctxt Assumption
remainingUndischarged ctxt subCtxt =
  deleteFirstsBy linearCancel (linears ctxt) (linears subCtxt)
    where
      linears = filter isLinear
      isLinear (_, Linear _) = True
      isLinear (_, _)        = False
      linearCancel (v, Linear _) (v', Linear _) = v == v'
      linearCancel (v, Linear _) (v', Discharged _ (CZero _)) = v == v'
      linearCancel (v, Discharged _ (CZero _)) (v', Linear _) = v == v'
      linearCancel (v, Discharged _ _) (v', Discharged _ _)    = v == v'
      linearCancel _ _ = False

leqAssumption ::
    Span -> (Id, Assumption) -> (Id, Assumption) -> MaybeT Checker ()

-- Linear assumptions ignored
leqAssumption _ (_, Linear _)        (_, Linear _) = return ()

-- Discharged coeffect assumptions
leqAssumption s (_, Discharged _ c1) (_, Discharged _ c2) = do
  kind <- mguCoeffectTypes s c1 c2
  addConstraint (Leq s c1 c2 kind)

leqAssumption s (x, t) (x', t') = do
  nameMap <- ask
  illTyped s $ "Can't unify free-variable types:\n\t"
           ++ pretty (unrename nameMap x, t)
           ++ "\nwith\n\t" ++ pretty (unrename nameMap x', t')


isType :: (Id, CKind) -> Bool
isType (_, CConstr "Type") = True
isType _                   = False

freshPolymorphicInstance :: TypeScheme -> MaybeT Checker Type
freshPolymorphicInstance (Forall s kinds ty) = do
    -- Universal becomes an existential (via freshCoeffeVar)
    -- since we are instantiating a polymorphic type
    renameMap <- mapM instantiateVariable kinds
    rename renameMap ty

  where
    -- Freshen variables, create existential instantiation
    instantiateVariable (var, k) = do
      -- Freshen the variable depending on its kind
      var' <- case k of
               KType -> do
                 var' <- freshVar var

                 -- Label fresh variable as an existential
                 modify (\st -> st { ckctxt = (var', (k, InstanceQ)) : ckctxt st })
                 return var'
               KConstr c -> freshCoeffectVar var (CConstr c)
               KCoeffect ->
                 error "Coeffect kind variables not yet supported"
      -- Return pair of old variable name and instantiated name (for
      -- name map)
      return (var, var')

    rename rmap = typeFoldM (baseTypeFold { tfBox = renameBox rmap
                                          , tfTyVar = renameTyVar rmap })
    renameBox renameMap c t = do
      let c' = substCoeffect (map (\(v, var) -> (v, CVar var)) renameMap) c
      return $ Box c' t
    renameTyVar renameMap v =
      case lookup v renameMap of
        Just v' -> return $ TyVar v'
        Nothing -> illTyped s $ "Type variable " ++ v ++ " is unbound"

relevantSubCtxt :: [Id] -> [(Id, t)] -> [(Id, t)]
relevantSubCtxt vars = filter relevant
 where relevant (var, _) = var `elem` vars


isNonLinearAssumption :: (Id, Assumption) -> Bool
isNonLinearAssumption (_, Discharged _ _) = True
isNonLinearAssumption _                   = False

-- Replace all top-level discharged coeffects with a variable
-- and derelict anything else
-- but add a var
discToFreshVarsIn :: Span -> [Id] -> Ctxt Assumption -> Coeffect -> MaybeT Checker (Ctxt Assumption)
discToFreshVarsIn s vars ctxt coeffect = mapM toFreshVar (relevantSubCtxt vars ctxt)
  where
    toFreshVar (var, Discharged t c) = do
      kind <- mguCoeffectTypes s c coeffect
      -- Create a fresh variable
      cvar  <- freshCoeffectVar var kind
      -- Return the freshened var-type mapping
      return (var, Discharged t (CVar cvar))

    toFreshVar (var, Linear t) = do
      kind <- inferCoeffectType s coeffect
      return (var, Discharged t (COne kind))


-- `freshVarsIn names ctxt` creates a new context with
-- all the variables names in `ctxt` that appear in the list
-- `vars` and are discharged are
-- turned into discharged coeffect assumptions annotated
-- with a fresh coeffect variable (and all variables not in
-- `vars` get deleted).
-- e.g.
--  `freshVarsIn ["x", "y"] [("x", Discharged (2, Int),
--                           ("y", Linear Int),
--                           ("z", Discharged (3, Int)]
--  -> [("x", Discharged (c5 :: Nat, Int),
--      ("y", Linear Int)]
--
freshVarsIn :: Span -> [Id] -> Ctxt Assumption -> MaybeT Checker (Ctxt Assumption)
freshVarsIn s vars ctxt = mapM toFreshVar (relevantSubCtxt vars ctxt)
  where
    toFreshVar (var, Discharged t c) = do
      ctype <- inferCoeffectType s c
      -- Create a fresh variable
      cvar  <- freshVar var
      -- Update the coeffect kind context
      modify (\s -> s { ckctxt = (cvar, (liftCoeffectType ctype, InstanceQ)) : ckctxt s })
      -- Return the freshened var-type mapping
      return (var, Discharged t (CVar cvar))

    toFreshVar (var, Linear t) = return (var, Linear t)

-- Combine two contexts
ctxPlus :: Span -> Ctxt Assumption -> Ctxt Assumption -> MaybeT Checker (Ctxt Assumption)
ctxPlus _ [] ctxt2 = return ctxt2
ctxPlus s ((i, v) : ctxt1) ctxt2 = do
  ctxt' <- extCtxt s ctxt2 i v
  ctxPlus s ctxt1 ctxt'

-- Erase a variable from the context
eraseVar :: Ctxt Assumption -> Id -> Ctxt Assumption
eraseVar [] _ = []
eraseVar ((var, t):ctxt) var' | var == var' = ctxt
                             | otherwise = (var, t) : eraseVar ctxt var'

-- ExtCtxt the context
extCtxt :: Span -> Ctxt Assumption -> Id -> Assumption -> MaybeT Checker (Ctxt Assumption)
extCtxt s ctxt var (Linear t) = do
  nameMap <- ask
  let var' = unrename nameMap var
  case lookup var ctxt of
    Just (Linear t') ->
       if t == t'
        then illLinearity s $ "Linear variable `" ++ var' ++ "` is used more than once.\n"
        else illTyped s $ "Type clash for variable `" ++ var' ++ "`"
    Just (Discharged t' c) ->
       if t == t'
         then do
           k <- inferCoeffectType s c
           return $ replace ctxt var (Discharged t (c `CPlus` COne k))
         else illTyped s $ "Type clash for variable " ++ var' ++ "`"
    Nothing -> return $ (var, Linear t) : ctxt

extCtxt s ctxt var (Discharged t c) = do
  nameMap <- ask
  case lookup var ctxt of
    Just (Discharged t' c') ->
        if t == t'
        then return $ replace ctxt var (Discharged t' (c `CPlus` c'))
        else do
          let var' = unrename nameMap var
          illTyped s $ "Type clash for variable `" ++ var' ++ "`"
    Just (Linear t') ->
        if t == t'
        then do
           k <- inferCoeffectType s c
           return $ replace ctxt var (Discharged t (c `CPlus` COne k))
        else do
          let var' = unrename nameMap var
          illTyped s $ "Type clash for variable " ++ var' ++ "`"
    Nothing -> return $ (var, Discharged t c) : ctxt

-- Helper, foldM on a list with at least one element
fold1M :: Monad m => (a -> a -> m a) -> [a] -> m a
fold1M _ []     = error "Must have at least one case"
fold1M f (x:xs) = foldM f x xs

print :: String -> MaybeT Checker ()
print = liftIO . putStrLn
  -- (\_ -> return ())

lookupMany :: Eq a => a -> [(a, b)] -> [b]
lookupMany _ []                     = []
lookupMany a' ((a, b):xs) | a == a' = b : lookupMany a' xs
lookupMany a' (_:xs)                = lookupMany a' xs