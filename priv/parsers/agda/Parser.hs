{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Main where

import qualified Agda.Syntax.Parser as P
import qualified Agda.Syntax.Parser.Monad as PM
import Agda.Syntax.Concrete
import Agda.Syntax.Position
import Agda.Syntax.Literal
import Agda.Syntax.Common
import Agda.Syntax.Common.Pretty
import Agda.Utils.FileName (mkAbsolute)
import qualified Agda.Utils.List1 as List1
import qualified Agda.Utils.List2 as List2
import qualified Data.Aeson as Aeson
import Data.Aeson ((.=))
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Char (isSpace)
import Data.List (isPrefixOf)
import GHC.Generics (Generic)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | Response wrapper for JSON output
data Response = Response
  { status :: String,
    ast :: Maybe Aeson.Value,
    errorMessage :: Maybe String
  }
  deriving (Generic, Show)

instance Aeson.ToJSON Response where
  toJSON = Aeson.genericToJSON Aeson.defaultOptions

hasModuleHeader :: String -> Bool
hasModuleHeader s =
  let nonCommentLines = filter (\l -> not (null l) && not ("--" `isPrefixOf` l)) $ map (dropWhile isSpace) (lines s)
  in case nonCommentLines of
       (l:_) -> "module " `isPrefixOf` l
       [] -> False

main :: IO ()
main = do
  args <- getArgs
  (sourceStr, filePathStr) <- case args of
    (path:_) -> do
      content <- TIO.readFile path
      return (T.unpack content, path)
    [] -> do
      content <- TIO.getContents
      return (T.unpack content, "/tmp/MetastaticTemp.agda")
  
  let rf = mkRangeFile (mkAbsolute filePathStr) Nothing
      pos = startPos Nothing

  if hasModuleHeader sourceStr
    then do
      moduleRes <- P.runPMIO (P.parseFile P.moduleParser rf sourceStr)
      case moduleRes of
        (Right ((mod, _attrs), _filetype), _warnings) ->
          outputSuccess (moduleToJson mod)
        (Left err, _warnings) -> do
          outputError (show err)
    else do
      exprRes <- P.runPMIO (P.parsePosString P.exprParser pos sourceStr)
      case exprRes of
        (Right (expr, _attrs), _) ->
          outputSuccess (exprToJson expr)
        (Left _exprErr, _) -> do
          let wrappedSource = "module _MetastaticTemp_ where\n" ++ unlines (map ("  " ++) (lines sourceStr))
          wrappedRes <- P.runPMIO (P.parseFile P.moduleParser rf wrappedSource)
          case wrappedRes of
            (Right ((wrappedMod, _), _), _) -> do
              let decls = modDecls wrappedMod
              outputSuccess $ Aeson.object
                [ "type" .= ("module" :: String)
                , "name" .= Aeson.Null
                , "declarations" .= map declToJson decls
                ]
            (Left err, _) ->
              outputError (show err)

outputError :: String -> IO ()
outputError errMsg = do
  hPutStrLn stderr $ "Parse error: " ++ errMsg
  BL.putStrLn $
    Aeson.encode $
      Response
        { status = "error"
        , ast = Nothing
        , errorMessage = Just errMsg
        }
  exitFailure

outputSuccess :: Aeson.Value -> IO ()
outputSuccess jsonVal = do
  BL.putStrLn $
    Aeson.encode $
      Response
        { status = "ok"
        , ast = Just jsonVal
        , errorMessage = Nothing
        }

-- Location helper
rangeToJson :: Range -> Aeson.Value
rangeToJson r = case (rStart r, rEnd r) of
  (Just s, Just e) -> Aeson.object
    [ "startLine" .= posLine s
    , "startCol"  .= posCol s
    , "endLine"   .= posLine e
    , "endCol"    .= posCol e
    ]
  _ -> Aeson.Null

qnameToString :: QName -> String
qnameToString qn = render (pretty qn)

nameToString :: Name -> String
nameToString n = render (pretty n)

moduleToJson :: Module -> Aeson.Value
moduleToJson (Mod _pragmas decls) =
  Aeson.object
    [ "type" .= ("module" :: String)
    , "declarations" .= map declToJson decls
    ]

declToJson :: Declaration -> Aeson.Value
declToJson decl = case decl of
  TypeSig _ _ name expr ->
    Aeson.object
      [ "type" .= ("type_sig" :: String)
      , "name" .= nameToString name
      , "signature" .= exprToJson expr
      , "location" .= rangeToJson (getRange name)
      ]
  FieldSig isInst _ name (Arg _ expr) ->
    Aeson.object
      [ "type" .= ("field_sig" :: String)
      , "name" .= nameToString name
      , "signature" .= exprToJson expr
      , "location" .= rangeToJson (getRange name)
      ]
  FunClause lhs rhs whereClause _ ->
    Aeson.object
      [ "type" .= ("fun_clause" :: String)
      , "lhs" .= lhsToJson lhs
      , "rhs" .= rhsToJson rhs
      , "where" .= whereToJson whereClause
      ]
  Data r _ name params expr constructors ->
    Aeson.object
      [ "type" .= ("data" :: String)
      , "name" .= nameToString name
      , "params" .= map lamBindToJson params
      , "typeExpr" .= exprToJson expr
      , "constructors" .= map declToJson constructors
      , "location" .= rangeToJson r
      ]
  Record r _ name _directives params expr fields ->
    Aeson.object
      [ "type" .= ("record" :: String)
      , "name" .= nameToString name
      , "params" .= map lamBindToJson params
      , "typeExpr" .= exprToJson expr
      , "fields" .= map declToJson fields
      , "location" .= rangeToJson r
      ]
  Module r _ qname _ decls ->
    Aeson.object
      [ "type" .= ("module" :: String)
      , "name" .= qnameToString qname
      , "declarations" .= map declToJson decls
      , "location" .= rangeToJson r
      ]
  Open r qname _ ->
    Aeson.object
      [ "type" .= ("open" :: String)
      , "module" .= qnameToString qname
      , "location" .= rangeToJson r
      ]
  Import r qname _ openShort _ ->
    let isOpen = case openShort of
                   DoOpen -> True
                   DontOpen -> False
    in Aeson.object
      [ "type" .= ("import" :: String)
      , "module" .= qnameToString qname
      , "open" .= isOpen
      , "location" .= rangeToJson r
      ]
  Postulate r sigs ->
    Aeson.object
      [ "type" .= ("postulate" :: String)
      , "declarations" .= map declToJson sigs
      , "location" .= rangeToJson (getRange r)
      ]
  Infix fixity names ->
    Aeson.object
      [ "type" .= ("infix_decl" :: String)
      , "fixity" .= render (pretty fixity)
      , "names" .= map nameToString (List1.toList names)
      ]
  _ ->
    Aeson.object
      [ "type" .= ("other_decl" :: String)
      , "text" .= render (pretty decl)
      ]

lhsToJson :: LHS -> Aeson.Value
lhsToJson (LHS origPat _ _) = patternToJson origPat

rhsToJson :: RHS -> Aeson.Value
rhsToJson rhs = case rhs of
  RHS expr -> Aeson.object
    [ "type" .= ("rhs" :: String)
    , "expression" .= exprToJson expr
    ]
  AbsurdRHS -> Aeson.object
    [ "type" .= ("absurd_rhs" :: String)
    ]

whereToJson :: WhereClause -> Aeson.Value
whereToJson whereClause = case whereClause of
  NoWhere -> Aeson.Null
  AnyWhere _ decls -> Aeson.object
    [ "declarations" .= map declToJson decls ]
  SomeWhere _ _ _ _ decls -> Aeson.object
    [ "declarations" .= map declToJson decls ]

patternToJson :: Pattern -> Aeson.Value
patternToJson pat = case pat of
  IdentP _ qn ->
    Aeson.object
      [ "type" .= ("var_pat" :: String)
      , "name" .= qnameToString qn
      , "location" .= rangeToJson (getRange qn)
      ]
  WildP r ->
    Aeson.object
      [ "type" .= ("wildcard" :: String)
      , "location" .= rangeToJson r
      ]
  LitP r lit ->
    Aeson.object
      [ "type" .= ("lit_pat" :: String)
      , "value" .= literalToJson lit
      , "location" .= rangeToJson r
      ]
  ParenP _ p -> patternToJson p
  RawAppP r pats ->
    let patList = List2.toList pats
    in case patList of
      [p1, IdentP _ op, p2] ->
        Aeson.object
          [ "type" .= ("infix_pat" :: String)
          , "operator" .= qnameToString op
          , "left" .= patternToJson p1
          , "right" .= patternToJson p2
          , "location" .= rangeToJson r
          ]
      _ ->
        Aeson.object
          [ "type" .= ("app_pat" :: String)
          , "elements" .= map patternToJson patList
          , "location" .= rangeToJson r
          ]
  AppP p (Arg _ (Named _ argP)) ->
    Aeson.object
      [ "type" .= ("app_pat" :: String)
      , "elements" .= [patternToJson p, patternToJson argP]
      ]
  HiddenP r (Named _ p) ->
    Aeson.object
      [ "type" .= ("hidden_pat" :: String)
      , "pattern" .= patternToJson p
      , "location" .= rangeToJson r
      ]
  InstanceP r (Named _ p) ->
    Aeson.object
      [ "type" .= ("instance_pat" :: String)
      , "pattern" .= patternToJson p
      , "location" .= rangeToJson r
      ]
  DotP _ r e ->
    Aeson.object
      [ "type" .= ("dot_pat" :: String)
      , "expression" .= exprToJson e
      , "location" .= rangeToJson r
      ]
  AbsurdP r ->
    Aeson.object
      [ "type" .= ("absurd_pat" :: String)
      , "location" .= rangeToJson r
      ]
  _ ->
    Aeson.object
      [ "type" .= ("other_pat" :: String)
      , "text" .= render (pretty pat)
      ]

exprToJson :: Expr -> Aeson.Value
exprToJson expr = case expr of
  Ident qn ->
    Aeson.object
      [ "type" .= ("var" :: String)
      , "name" .= qnameToString qn
      , "location" .= rangeToJson (getRange qn)
      ]
  Lit r lit ->
    Aeson.object
      [ "type" .= ("literal" :: String)
      , "value" .= literalToJson lit
      , "location" .= rangeToJson r
      ]
  RawApp r es ->
    let exprList = List2.toList es
    in case exprList of
      [e1, Ident op, e2] ->
        Aeson.object
          [ "type" .= ("infix" :: String)
          , "operator" .= qnameToString op
          , "left" .= exprToJson e1
          , "right" .= exprToJson e2
          , "location" .= rangeToJson r
          ]
      _ ->
        Aeson.object
          [ "type" .= ("raw_app" :: String)
          , "elements" .= map exprToJson exprList
          , "location" .= rangeToJson r
          ]
  App r func (Arg _ (Named _ arg)) ->
    Aeson.object
      [ "type" .= ("app" :: String)
      , "function" .= exprToJson func
      , "argument" .= exprToJson arg
      , "location" .= rangeToJson r
      ]
  Lam r lamBinds body ->
    Aeson.object
      [ "type" .= ("lambda" :: String)
      , "parameters" .= map lamBindToJson (List1.toList lamBinds)
      , "body" .= exprToJson body
      , "location" .= rangeToJson r
      ]
  Fun r (Arg _ arg) res ->
    Aeson.object
      [ "type" .= ("arrow" :: String)
      , "from" .= exprToJson arg
      , "to" .= exprToJson res
      , "location" .= rangeToJson r
      ]
  Pi tel res ->
    Aeson.object
      [ "type" .= ("pi" :: String)
      , "telescope" .= map telToJson (List1.toList tel)
      , "target" .= exprToJson res
      ]
  Paren _ e -> exprToJson e
  Let r decls maybeBody ->
    Aeson.object
      [ "type" .= ("let" :: String)
      , "declarations" .= map declToJson (List1.toList decls)
      , "body" .= case maybeBody of
                    Just b -> exprToJson b
                    Nothing -> Aeson.Null
      , "location" .= rangeToJson r
      ]
  QuestionMark r _ ->
    Aeson.object
      [ "type" .= ("hole" :: String)
      , "location" .= rangeToJson r
      ]
  Underscore r _ ->
    Aeson.object
      [ "type" .= ("wildcard" :: String)
      , "location" .= rangeToJson r
      ]
  _ ->
    Aeson.object
      [ "type" .= ("other_expr" :: String)
      , "text" .= render (pretty expr)
      , "location" .= rangeToJson (getRange expr)
      ]

literalToJson :: Literal -> Aeson.Value
literalToJson lit = case lit of
  LitNat n ->
    Aeson.object
      [ "literalType" .= ("int" :: String)
      , "value" .= n
      ]
  LitWord64 w ->
    Aeson.object
      [ "literalType" .= ("int" :: String)
      , "value" .= toInteger w
      ]
  LitFloat d ->
    Aeson.object
      [ "literalType" .= ("float" :: String)
      , "value" .= d
      ]
  LitString s ->
    Aeson.object
      [ "literalType" .= ("string" :: String)
      , "value" .= s
      ]
  LitChar c ->
    Aeson.object
      [ "literalType" .= ("char" :: String)
      , "value" .= [c]
      ]
  LitQName q ->
    Aeson.object
      [ "literalType" .= ("qname" :: String)
      , "value" .= render (pretty q)
      ]
  LitMeta _ _ ->
    Aeson.object
      [ "literalType" .= ("meta" :: String)
      ]

lamBindToJson :: LamBinding -> Aeson.Value
lamBindToJson lb = case lb of
  DomainFree (Arg ai (Named _ b)) ->
    Aeson.object
      [ "type" .= ("domain_free" :: String)
      , "name" .= render (pretty b)
      , "implicit" .= (getHiding ai == Hidden)
      ]
  DomainFull tb ->
    Aeson.object
      [ "type" .= ("domain_full" :: String)
      , "text" .= render (pretty tb)
      ]

telToJson :: TypedBinding -> Aeson.Value
telToJson tb =
  Aeson.object
    [ "type" .= ("typed_binding" :: String)
    , "text" .= render (pretty tb)
    ]
