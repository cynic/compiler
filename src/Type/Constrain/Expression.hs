{-# OPTIONS_GHC -Wall #-}
module Type.Constrain.Expression where

import Control.Applicative ((<$>))
import qualified Control.Monad as Monad
import qualified Data.List as List
import qualified Data.Map as Map

import qualified AST.Expression.General as E
import qualified AST.Expression.Canonical as Canonical
import qualified AST.Literal as Lit
import qualified AST.Pattern as P
import qualified AST.Type as ST
import qualified AST.Variable as V
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Type as Error
import qualified Reporting.Region as R
import qualified Type.Constrain.Literal as Literal
import qualified Type.Constrain.Pattern as Pattern
import qualified Type.Environment as Env
import qualified Type.Fragment as Fragment
import Type.Type hiding (Descriptor(..))


constrain
    :: Env.Environment
    -> Canonical.Expr
    -> Type
    -> IO TypeConstraint
constrain env (A.A region expression) tipe =
    let list t = Env.get env Env.types "List" <| t
        (===) = CEqual Error.None region
        (<?) = CInstance region
    in
    case expression of
      E.Literal lit ->
          Literal.constrain env region lit tipe

      E.GLShader _uid _src gltipe ->
          exists $ \attr ->
          exists $ \unif ->
            let
                shaderTipe a u v =
                    Env.get env Env.types "WebGL.Shader" <| a <| u <| v

                glTipe =
                    Env.get env Env.types . Lit.glTipeName

                makeRec accessor baseRec =
                    let decls = accessor gltipe
                    in
                      if Map.size decls == 0
                        then baseRec
                        else record (Map.map (\t -> [glTipe t]) decls) baseRec

                attribute = makeRec Lit.attribute attr
                uniform = makeRec Lit.uniform unif
                varying = makeRec Lit.varying (termN EmptyRecord1)
            in
                return (tipe === shaderTipe attribute uniform varying)

      E.Var var ->
          let name = V.toString var
          in
              return (if name == E.saveEnvName then CSaveEnv else name <? tipe)

      E.Range lowExpr highExpr ->
          existsNumber $ \n ->
              do  lowCon <- constrain env lowExpr n
                  highCon <- constrain env highExpr n
                  return $ CAnd [lowCon, highCon, list n === tipe]

      E.ExplicitList exprs ->
          constrainList env region exprs tipe

      E.Binop op leftExpr rightExpr ->
          exists $ \leftType ->
          exists $ \rightType ->
              do  leftCon <- constrain env leftExpr leftType
                  rightCon <- constrain env rightExpr rightType
                  return $ CAnd
                    [ leftCon
                    , rightCon
                    , V.toString op <? (leftType ==> rightType ==> tipe)
                    ]

      E.Lambda pattern body ->
          exists $ \argType ->
          exists $ \resType ->
              do  fragment <- Pattern.constrain env pattern argType
                  bodyCon <- constrain env body resType
                  let con =
                        ex (Fragment.vars fragment)
                            (CLet [monoscheme (Fragment.typeEnv fragment)]
                                  (Fragment.typeConstraint fragment /\ bodyCon)
                            )
                  return $ con /\ tipe === (argType ==> resType)

      E.App func arg ->
          do  argVar <- variable Flexible
              resultVar <- variable Flexible
              argCon <- constrain env arg (varN argVar)
              funcCon <- constrain env func (varN argVar ==> varN resultVar)
              let appCon = tipe === varN resultVar
              return $
                ex [argVar,resultVar] (CAnd [ argCon, funcCon, appCon ])

      E.MultiIf branches ->
          constrainIf env region branches tipe

      E.Case expr branches ->
          constrainCase env region expr branches tipe

      E.Data name exprs ->
          do  vars <- Monad.forM exprs $ \_ -> variable Flexible
              let pairs = zip exprs (map varN vars)
              (ctipe, cs) <- Monad.foldM step (tipe, CTrue) (reverse pairs)
              return $ ex vars (cs /\ name <? ctipe)
          where
            step (t,c) (e,x) =
                do  c' <- constrain env e x
                    return (x ==> t, c /\ c')

      E.Access expr label ->
          exists $ \t ->
              constrain env expr (record (Map.singleton label [tipe]) t)

      E.Remove expr label ->
          exists $ \t ->
              constrain env expr (record (Map.singleton label [t]) tipe)

      E.Insert expr label value ->
          exists $ \valueType ->
          exists $ \recordType ->
              do  valueCon <- constrain env value valueType
                  recordCon <- constrain env expr recordType
                  let newRecordType =
                        record (Map.singleton label [valueType]) recordType
                  return (CAnd [valueCon, recordCon, tipe === newRecordType])

      E.Modify expr fields ->
          exists $ \t ->
              do  oldVars <- Monad.forM fields $ \_ -> variable Flexible
                  let oldFields = ST.fieldMap (zip (map fst fields) (map varN oldVars))
                  cOld <- ex oldVars <$> constrain env expr (record oldFields t)

                  newVars <- Monad.forM fields $ \_ -> variable Flexible
                  let newFields = ST.fieldMap (zip (map fst fields) (map varN newVars))
                  let cNew = tipe === record newFields t

                  cs <- Monad.zipWithM (constrain env) (map snd fields) (map varN newVars)

                  return $ cOld /\ ex newVars (CAnd (cNew : cs))

      E.Record fields ->
          do  vars <- Monad.forM fields (\_ -> variable Flexible)
              fieldCons <-
                  Monad.zipWithM
                      (constrain env)
                      (map snd fields)
                      (map varN vars)
              let fields' = ST.fieldMap (zip (map fst fields) (map varN vars))
              let recordType = record fields' (termN EmptyRecord1)
              return (ex vars (CAnd (fieldCons ++ [tipe === recordType])))

      E.Let defs body ->
          do  bodyCon <- constrain env body tipe

              (Info schemes rqs fqs headers c2 c1) <-
                  Monad.foldM
                      (constrainDef env)
                      (Info [] [] [] Map.empty CTrue CTrue)
                      (concatMap expandPattern defs)

              let letScheme = [ Scheme rqs fqs (CLet [monoscheme headers] c2) headers ]

              return $ CLet schemes (CLet letScheme (c1 /\ bodyCon))

      E.Port impl ->
          case impl of
            E.In _ _ ->
                return CTrue

            E.Out _ expr _ ->
                constrain env expr tipe

            E.Task _ expr _ ->
                constrain env expr tipe


-- CONSTRAIN LISTS

constrainList
    :: Env.Environment
    -> R.Region
    -> [Canonical.Expr]
    -> Type
    -> IO TypeConstraint
constrainList env region exprs tipe =
  do  (exprInfo, exprCons) <-
          unzip <$> mapM elementConstraint exprs

      let pairwiseCons = pairwiseConstraints 2 exprInfo

      return $
        ex  (map fst exprInfo)
            (CAnd (exprCons ++ pairwiseCons))
  where
    list t =
      Env.get env Env.types "List" <| t

    elementConstraint expr@(A.A region' _) =
      do  var <- variable Flexible
          con <- constrain env expr (varN var)
          return ( (var, region'), con )

    pairwiseConstraints n exprInfo =
      case exprInfo of
        [] ->
            []

        (var,_) : [] ->
            [ CEqual Error.List region tipe (list (varN var)) ]

        (var,_) : (var',region') : rest ->
            let
              hint = Error.ListElement n region'
              con = CEqual hint region (varN var) (varN var')
            in
              con : pairwiseConstraints (n+1) ((var', region') : rest)


-- CONSTRAIN IF EXPRESSIONS

constrainIf
    :: Env.Environment
    -> R.Region
    -> [(Canonical.Expr, Canonical.Expr)]
    -> Type
    -> IO TypeConstraint
constrainIf env region branches tipe =
  do  (branchInfo, branchExprCons) <-
          unzip <$> mapM constrainBranch branches

      return $
        ex  (map fst branchInfo)
            (CAnd (branchExprCons ++ branchCons branchInfo))
  where
    bool = Env.get env Env.types "Bool"

    constrainBranch (cond, expr@(A.A branchRegion _)) =
      do  branchVar <- variable Flexible
          condCon <- constrain env cond bool
          exprCon <- constrain env expr (varN branchVar)
          return
            ( (branchVar, branchRegion)
            , condCon /\ exprCon
            )

    branchCons branchInfo =
      case branchInfo of
        [(thenVar, _), (elseVar, _)] ->
            [ CEqual Error.IfBranches region (varN thenVar) (varN elseVar)
            , CEqual Error.If region tipe (varN thenVar)
            ]

        _ ->
            buildBranchCons 2 branchInfo

    buildBranchCons n branchInfo =
      case branchInfo of
        [] ->
            []

        (var,_) : [] ->
            [ CEqual Error.If region tipe (varN var) ]

        (var,_) : (var',region') : rest ->
            let
              hint = Error.MultiIfBranch n region'
              con = CEqual hint region (varN var) (varN var')
            in
              con : buildBranchCons (n+1) ((var', region') : rest)


-- CONSTRAIN CASE EXPRESSIONS

constrainCase
    :: Env.Environment
    -> R.Region
    -> Canonical.Expr
    -> [(P.CanonicalPattern, Canonical.Expr)]
    -> Type
    -> IO TypeConstraint
constrainCase env region expr branches tipe =
  do  exprVar <- variable Flexible

      exprCon <- constrain env expr (varN exprVar)

      (branchInfo, branchExprCons) <-
          unzip <$> mapM (branch (varN exprVar)) branches

      return $
        ex  (exprVar : map fst branchInfo)
            (CAnd (exprCon : branchExprCons ++ branchCons 2 branchInfo))
  where
    branch patternType (pattern, branchExpr@(A.A branchRegion _)) =
        do  branchVar <- variable Flexible
            fragment <- Pattern.constrain env pattern patternType
            branchCon <- constrain env branchExpr (varN branchVar)
            return
                ( (branchVar, branchRegion)
                , CLet [Fragment.toScheme fragment] branchCon
                )

    branchCons n branchInfo =
      case branchInfo of
        [] ->
            []

        (var,_) : [] ->
            [ CEqual Error.Case region tipe (varN var) ]

        (var,_) : (var',region') : rest ->
            let
              hint = Error.CaseBranch n region'
              con = CEqual hint region (varN var) (varN var')
            in
              con : branchCons (n+1) ((var', region') : rest)


-- EXPAND PATTERNS

expandPattern :: Canonical.Def -> [Canonical.Def]
expandPattern def@(Canonical.Definition lpattern expr maybeType) =
  let (A.A patternRegion pattern) = lpattern
  in
  case pattern of
    P.Var _ ->
        [def]

    _ ->
        mainDef : map toDef vars
      where
        vars = P.boundVarList lpattern

        combinedName = "$" ++ concat vars

        pvar name =
            A.A patternRegion (P.Var name)

        localVar name =
            A.A patternRegion (E.localVar name)

        mainDef = Canonical.Definition (pvar combinedName) expr maybeType

        toDef name =
            let extract =
                  E.Case (localVar combinedName) [(lpattern, localVar name)]
            in
                Canonical.Definition (pvar name) (A.A patternRegion extract) Nothing


-- CONSTRAIN DEFINITIONS

data Info = Info
    { iSchemes :: [TypeScheme]
    , iRigid :: [Variable]
    , iFlex :: [Variable]
    , iHeaders :: Map.Map String Type
    , iC2 :: TypeConstraint
    , iC1 :: TypeConstraint
    }


constrainDef :: Env.Environment -> Info -> Canonical.Def -> IO Info
constrainDef env info (Canonical.Definition (A.A _ pattern) expr maybeTipe) =
  let qs = [] -- should come from the def, but I'm not sure what would live there...
  in
  case (pattern, maybeTipe) of
    (P.Var name, Just tipe) ->
        constrainAnnotatedDef env info qs name expr tipe

    (P.Var name, Nothing) ->
        constrainUnannotatedDef env info qs name expr

    _ -> error ("problem in constrainDef with " ++ show pattern)


constrainAnnotatedDef
    :: Env.Environment
    -> Info
    -> [String]
    -> String
    -> Canonical.Expr
    -> ST.Canonical
    -> IO Info
constrainAnnotatedDef env info qs name expr tipe =
  do  -- Some mistake may be happening here. Currently, qs is always [].
      rigidVars <- Monad.forM qs (\_ -> variable Rigid)

      flexiVars <- Monad.forM qs (\_ -> variable Flexible)

      let inserts = zipWith (\arg typ -> Map.insert arg (varN typ)) qs flexiVars

      let env' = env { Env.value = List.foldl' (\x f -> f x) (Env.value env) inserts }

      (vars, typ) <- Env.instantiateType env tipe Map.empty

      let scheme =
            Scheme
            { rigidQuantifiers = []
            , flexibleQuantifiers = flexiVars ++ vars
            , constraint = CTrue
            , header = Map.singleton name typ
            }

      c <- constrain env' expr typ

      return $ info
          { iSchemes = scheme : iSchemes info
          , iC1 = fl rigidVars c /\ iC1 info
          }


constrainUnannotatedDef
    :: Env.Environment
    -> Info
    -> [String]
    -> String
    -> Canonical.Expr
    -> IO Info
constrainUnannotatedDef env info qs name expr =
  do  -- Some mistake may be happening here. Currently, qs is always [].
      rigidVars <- Monad.forM qs (\_ -> variable Rigid)

      v <- variable Flexible

      let tipe = varN v

      let inserts = zipWith (\arg typ -> Map.insert arg (varN typ)) qs rigidVars

      let env' = env { Env.value = List.foldl' (\x f -> f x) (Env.value env) inserts }

      c <- constrain env' expr tipe

      return $ info
          { iRigid = rigidVars ++ iRigid info
          , iFlex = v : iFlex info
          , iHeaders = Map.insert name tipe (iHeaders info)
          , iC2 = c /\ iC2 info
          }
