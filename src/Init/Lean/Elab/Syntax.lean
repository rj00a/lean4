/-
Copyright (c) 2020 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
prelude
import Init.Lean.Elab.Command
import Init.Lean.Elab.Quotation

namespace Lean
namespace Elab

namespace Term

/-
Expand `optional «precedence»` where
 «precedence» := parser! " : " >> precedenceLit
 precedenceLit : Parser := numLit <|> maxPrec
 maxPrec := parser! nonReservedSymbol "max" -/
private def expandOptPrecedence (stx : Syntax) : Option Nat :=
if stx.isNone then none
else match ((stx.getArg 0).getArg 1).isNatLit? with
  | some v => some v
  | _      => some Parser.appPrec

private def mkParserSeq (ds : Array Syntax) : TermElabM Syntax :=
if ds.size == 0 then
  throwUnsupportedSyntax
else if ds.size == 1 then
  pure $ ds.get! 0
else
  ds.foldlFromM (fun r d => `(ParserDescr.andthen $r $d)) (ds.get! 0) 1

structure ToParserDescrContext :=
(catName              : Name)
(first                : Bool)
(pushLeadingAllowed   : Bool)
/- When `leadingIdentAsSymbol == true` we convert
   `Lean.Parser.Syntax.atom` into `Lean.ParserDescr.nonReservedSymbol`
   See comment at `Parser.ParserCategory`. -/
(leadingIdentAsSymbol : Bool)

abbrev ToParserDescrM := ReaderT ToParserDescrContext (StateT Bool TermElabM)
private def markAsTrailingParser : ToParserDescrM Unit := set true

@[inline] private def withFirst {α} (first : Bool) (x : ToParserDescrM α) : ToParserDescrM α :=
adaptReader (fun (ctx : ToParserDescrContext) => { first := ctx.first && first, .. ctx }) x

@[inline] private def withNoPushLeading {α} (x : ToParserDescrM α) : ToParserDescrM α :=
adaptReader (fun (ctx : ToParserDescrContext) => { pushLeadingAllowed := false, .. ctx }) x

partial def toParserDescrAux : Syntax → ToParserDescrM Syntax
| stx =>
  let kind := stx.getKind;
  if kind == nullKind then do
     args ← stx.getArgs.mapIdxM $ fun i arg => withFirst (i == 0) (toParserDescrAux arg);
     liftM $ mkParserSeq args
  else if kind == choiceKind then do
    toParserDescrAux (stx.getArg 0)
  else if kind == `Lean.Parser.Syntax.paren then
    toParserDescrAux (stx.getArg 1)
  else if kind == `Lean.Parser.Syntax.cat then do
    let cat := (stx.getIdAt 0).eraseMacroScopes;
    let rbp? : Option Nat  := expandOptPrecedence (stx.getArg 1);
    env ← liftM getEnv;
    unless (Parser.isParserCategory env cat) $ liftM $ throwError (stx.getArg 3) ("unknown category '" ++ cat ++ "'");
    ctx ← read;
    if ctx.first && cat == ctx.catName then do
      unless rbp?.isNone $ liftM $ throwError (stx.getArg 1) ("invalid occurrence of ':<num>' modifier in head");
      ctx ← read;
      unless ctx.pushLeadingAllowed $ liftM $
        throwError (stx.getArg 3) ("invalid occurrence of '" ++ cat ++ "', parser algorithm does not allow this form of left recursion");
      markAsTrailingParser; -- mark as trailing par
      `(ParserDescr.pushLeading)
    else
      let rbp := rbp?.getD 0;
      `(ParserDescr.parser $(quote cat) $(quote rbp))
  else if kind == `Lean.Parser.Syntax.atom then do
    match (stx.getArg 0).isStrLit? with
    | some atom => do
      let rbp? : Option Nat  := expandOptPrecedence (stx.getArg 1);
      ctx ← read;
      if ctx.leadingIdentAsSymbol && rbp?.isNone then
        `(ParserDescr.nonReservedSymbol $(quote atom) false)
      else
        `(ParserDescr.symbol $(quote atom) $(quote rbp?))
    | none => liftM throwUnsupportedSyntax
  else if kind == `Lean.Parser.Syntax.num then
    `(ParserDescr.num)
  else if kind == `Lean.Parser.Syntax.str then
    `(ParserDescr.str)
  else if kind == `Lean.Parser.Syntax.char then
    `(ParserDescr.char)
  else if kind == `Lean.Parser.Syntax.ident then
    `(ParserDescr.ident)
  else if kind == `Lean.Parser.Syntax.try then do
    d ← withNoPushLeading $ toParserDescrAux (stx.getArg 1);
    `(ParserDescr.try $d)
  else if kind == `Lean.Parser.Syntax.lookahead then do
    d ← withNoPushLeading $ toParserDescrAux (stx.getArg 1);
    `(ParserDescr.lookahead $d)
  else if kind == `Lean.Parser.Syntax.optional then do
    d ← withNoPushLeading $ toParserDescrAux (stx.getArg 1);
    `(ParserDescr.optional $d)
  else if kind == `Lean.Parser.Syntax.sepBy then do
    d₁ ← withNoPushLeading $ toParserDescrAux (stx.getArg 1);
    d₂ ← withNoPushLeading $ toParserDescrAux (stx.getArg 2);
    `(ParserDescr.sepBy $d₁ $d₂)
  else if kind == `Lean.Parser.Syntax.sepBy1 then do
    d₁ ← withNoPushLeading $ toParserDescrAux (stx.getArg 1);
    d₂ ← withNoPushLeading $ toParserDescrAux (stx.getArg 2);
    `(ParserDescr.sepBy1 $d₁ $d₂)
  else if kind == `Lean.Parser.Syntax.many then do
    d ← withNoPushLeading $ toParserDescrAux (stx.getArg 0);
    `(ParserDescr.many $d)
  else if kind == `Lean.Parser.Syntax.many1 then do
    d ← withNoPushLeading $ toParserDescrAux (stx.getArg 0);
    `(ParserDescr.many1 $d)
  else if kind == `Lean.Parser.Syntax.orelse then do
    d₁ ← withNoPushLeading $ toParserDescrAux (stx.getArg 0);
    d₂ ← withNoPushLeading $ toParserDescrAux (stx.getArg 2);
    `(ParserDescr.orelse $d₁ $d₂)
  else
    liftM $ throwUnsupportedSyntax

/--
  Given a `stx` of category `syntax`, return a pair `(newStx, trailingParser)`,
  where `newStx` is of category `term`. After elaboration, `newStx` should have type
  `TrailingParserDescr` if `trailingParser == true`, and `ParserDescr` otherwise. -/
def toParserDescr (stx : Syntax) (catName : Name) : TermElabM (Syntax × Bool) := do
env ← getEnv;
let leadingIdentAsSymbol := Parser.leadingIdentAsSymbol env catName;
(toParserDescrAux stx { catName := catName, first := true, pushLeadingAllowed := true, leadingIdentAsSymbol := leadingIdentAsSymbol }).run false

end Term

namespace Command

@[builtinCommandElab syntaxCat] def elabDeclareSyntaxCat : CommandElab :=
fun stx => do
  let catName  := stx.getIdAt 1;
  let attrName := catName.appendAfter "Parser";
  env ← getEnv;
  env ← liftIO stx $ Parser.registerParserCategory env attrName catName;
  setEnv env

def mkKindName (catName : Name) : Name :=
`_kind ++ catName

def mkFreshKind (catName : Name) : CommandElabM Name := do
scp ← getCurrMacroScope;
mainModule ← getMainModule;
pure $ Lean.addMacroScope mainModule (mkKindName catName) scp

def Macro.mkFreshKind (catName : Name) : MacroM Name :=
Macro.addMacroScope (mkKindName catName)

private def elabKind (stx : Syntax) (catName : Name) : CommandElabM Name := do
if stx.isNone then
  mkFreshKind catName
else
  let kind := stx.getIdAt 1;
  if kind.hasMacroScopes then
    pure kind
  else do
    currNamespace ← getCurrNamespace;
    pure (currNamespace ++ kind)

@[builtinCommandElab «syntax»] def elabSyntax : CommandElab :=
fun stx => do
  env ← getEnv;
  let cat := (stx.getIdAt 4).eraseMacroScopes;
  unless (Parser.isParserCategory env cat) $ throwError (stx.getArg 4) ("unknown category '" ++ cat ++ "'");
  kind ← elabKind (stx.getArg 1) cat;
  let catParserId := mkIdentFrom stx (cat.appendAfter "Parser");
  (val, trailingParser) ← runTermElabM none $ fun _ => Term.toParserDescr (stx.getArg 2) cat;
  type ← if trailingParser then `(Lean.TrailingParserDescr) else `(Lean.ParserDescr);
  -- TODO: meaningful, unhygienic def name for selective parser `open`ing?
  d ← `(@[$catParserId:ident] def myParser : $type := ParserDescr.node $(quote kind) $val);
  trace `Elab stx $ fun _ => d;
  withMacroExpansion stx d $ elabCommand d

@[builtinCommandElab «macro_rules»] def elabMacroRules : CommandElab :=
adaptExpander $ fun stx => match_syntax stx with
| `(macro_rules $alts*) => do
  -- TODO: clean up with matchAlt quotation
  k ← match_syntax ((alts.get! 0).getArg 1).getArg 0 with
  | `(`($quot)) => pure quot.getKind
  | stx         => throwUnsupportedSyntax;
  -- TODO: meaningful, unhygienic def name for selective macro `open`ing?
  `(@[macro $(Lean.mkIdent k)] def myMacro : Macro := fun stx => match_syntax stx with $alts* | _ => throw Lean.Macro.Exception.unsupportedSyntax)
| _ => throwUnsupportedSyntax

/- We just ignore Lean3 notation declaration commands. -/
@[builtinCommandElab «mixfix»] def elabMixfix : CommandElab := fun _ => pure ()
@[builtinCommandElab «reserve»] def elabReserve : CommandElab := fun _ => pure ()

/- Wrap all occurrences of the given `ident` nodes in antiquotations -/
private partial def antiquote (vars : Array Syntax) : Syntax → Syntax
| stx => match_syntax stx with
| `($id:ident) =>
  if (vars.findIdx? (fun var => var.getId == id.getId)).isSome then
    Syntax.node `antiquot #[mkAtom "$", Unhygienic.run `($id:ident), mkNullNode, mkNullNode]
  else
    stx
| _ => match stx with
  | Syntax.node k args => Syntax.node k (args.map antiquote)
  | stx => stx

/- Convert `notation` command lhs item into a `syntax` command item -/
def expandNotationItemIntoSyntaxItem (stx : Syntax) : MacroM Syntax :=
let k := stx.getKind;
if k == `Lean.Parser.Command.identPrec then
  pure $ Syntax.node `Lean.Parser.Syntax.cat #[mkIdentFrom stx `term,  stx.getArg 1]
else if k == `Lean.Parser.Command.quotedSymbolPrec then
  match (stx.getArg 0).getArg 1 with
  | Syntax.atom info val => pure $ Syntax.node `Lean.Parser.Syntax.atom #[mkStxStrLit val info, stx.getArg 1]
  | _                    => Macro.throwUnsupported
else if k == `Lean.Parser.Command.strLitPrec then
  pure $ Syntax.node `Lean.Parser.Syntax.atom stx.getArgs
else
  Macro.throwUnsupported

def strLitPrecToPattern (stx: Syntax) : MacroM Syntax :=
match (stx.getArg 0).isStrLit? with
| some str => pure $ mkAtomFrom stx str
| none     => Macro.throwUnsupported

/- Convert `notation` command lhs item a pattern element -/
def expandNotationItemIntoPattern (stx : Syntax) : MacroM Syntax :=
let k := stx.getKind;
if k == `Lean.Parser.Command.identPrec then
  let item := stx.getArg 0;
  pure $ mkNode `antiquot #[mkAtom "$", mkTermIdFromIdent item, mkNullNode, mkNullNode]
else if k == `Lean.Parser.Command.quotedSymbolPrec then
  pure $ (stx.getArg 0).getArg 1
else if k == `Lean.Parser.Command.strLitPrec then
  strLitPrecToPattern stx
else
  Macro.throwUnsupported

@[builtinMacro Lean.Parser.Command.notation] def expandNotation : Macro :=
fun stx => match_syntax stx with
| `(notation $items* => $rhs) => do
  kind ← Macro.mkFreshKind `term;
  -- build parser
  syntaxParts ← items.mapM expandNotationItemIntoSyntaxItem;
  let cat := mkIdentFrom stx `term;
  -- build macro rules
  let vars := items.filter $ fun item => item.getKind == `Lean.Parser.Command.identPrec;
  let vars := vars.map $ fun var => var.getArg 0;
  let rhs := antiquote vars rhs;
  patArgs ← items.mapM expandNotationItemIntoPattern;
  let pat := Syntax.node kind patArgs;
  `(syntax [$(mkIdentFrom stx kind)] $syntaxParts* : $cat macro_rules | `($pat) => `($rhs))
| _ => Macro.throwUnsupported

/- Convert `macro` argument into a `syntax` command item -/
def expandMacroArgIntoSyntaxItem (stx : Syntax) : MacroM Syntax :=
let k := stx.getKind;
if k == `Lean.Parser.Command.macroArgSimple then
  let argType := stx.getArg 2;
  match argType with
  | Syntax.atom _ "ident" => pure $ Syntax.node `Lean.Parser.Syntax.ident #[argType]
  | Syntax.atom _ "num"   => pure $ Syntax.node `Lean.Parser.Syntax.num #[argType]
  | Syntax.atom _ "str"   => pure $ Syntax.node `Lean.Parser.Syntax.str #[argType]
  | Syntax.atom _ "char"  => pure $ Syntax.node `Lean.Parser.Syntax.char #[argType]
  | Syntax.ident _ _ _ _  => pure $ Syntax.node `Lean.Parser.Syntax.cat #[stx.getArg 2,  stx.getArg 3]
  | _                     => Macro.throwUnsupported
else if k == `Lean.Parser.Command.strLitPrec then
  pure $ Syntax.node `Lean.Parser.Syntax.atom stx.getArgs
else
  Macro.throwUnsupported

/- Convert `macro` head into a `syntax` command item -/
def expandMacroHeadIntoSyntaxItem (stx : Syntax) : MacroM Syntax :=
let k := stx.getKind;
if k == `Lean.Parser.Command.identPrec then
  let info := stx.getHeadInfo;
  let id   := (stx.getArg 0).getId;
  pure $ Syntax.node `Lean.Parser.Syntax.atom #[mkStxStrLit (toString id) info, stx.getArg 1]
else
  expandMacroArgIntoSyntaxItem stx

/- Convert `macro` arg into a pattern element -/
def expandMacroArgIntoPattern (stx : Syntax) : MacroM Syntax :=
let k := stx.getKind;
if k == `Lean.Parser.Command.macroArgSimple then
  let item := stx.getArg 0;
  pure $ mkNode `antiquot #[mkAtom "$", mkTermIdFromIdent item, mkNullNode, mkNullNode]
else if k == `Lean.Parser.Command.strLitPrec then
  strLitPrecToPattern stx
else
  Macro.throwUnsupported

/- Convert `macro` head into a pattern element -/
def expandMacroHeadIntoPattern (stx : Syntax) : MacroM Syntax :=
let k := stx.getKind;
if k == `Lean.Parser.Command.identPrec then
  let str := toString (stx.getArg 0).getId;
  pure $ mkAtomFrom stx str
else
  expandMacroArgIntoPattern stx

@[builtinMacro Lean.Parser.Command.macro] def expandMacro : Macro :=
fun stx => do
  let head := stx.getArg 1;
  let args := (stx.getArg 2).getArgs;
  let cat  := stx.getArg 4;
  kind ← Macro.mkFreshKind (cat.getId).eraseMacroScopes;
  -- build parser
  stxPart  ← expandMacroHeadIntoSyntaxItem head;
  stxParts ← args.mapM expandMacroArgIntoSyntaxItem;
  let stxParts := #[stxPart] ++ stxParts;
  -- build macro rules
  patHead ← expandMacroHeadIntoPattern head;
  patArgs ← args.mapM expandMacroArgIntoPattern;
  let pat := Syntax.node kind (#[patHead] ++ patArgs);
  if stx.getArgs.size == 7 then
    -- `stx` is of the form `macro $head $args* : $cat => term`
    let rhs := stx.getArg 6;
    `(syntax [$(mkIdentFrom stx kind)] $stxParts* : $cat macro_rules | `($pat) => $rhs)
  else
    -- `stx` is of the form `macro $head $args* : $cat => `( $body )`
    let rhsBody := stx.getArg 7;
    `(syntax [$(mkIdentFrom stx kind)] $stxParts* : $cat macro_rules | `($pat) => `($rhsBody))

@[init] private def regTraceClasses : IO Unit := do
registerTraceClass `Elab.syntax;
pure ()

end Command
end Elab
end Lean
