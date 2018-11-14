(******************************************************************************)
(*                                                                            *)
(*                                   Menhir                                   *)
(*                                                                            *)
(*                       François Pottier, Inria Paris                        *)
(*              Yann Régis-Gianas, PPS, Université Paris Diderot              *)
(*                                                                            *)
(*  Copyright Inria. All rights reserved. This file is distributed under the  *)
(*  terms of the GNU General Public License version 2, as described in the    *)
(*  file LICENSE.                                                             *)
(*                                                                            *)
(******************************************************************************)

let position = Positions.position
open Keyword
type sw = Action.sw
open UnparameterizedSyntax
open ListMonad
let drop = MenhirLib.General.drop
let take = MenhirLib.General.take

(* -------------------------------------------------------------------------- *)

(* Throughout this file, branches (productions) are represented as lists of
   producers. We consider it acceptable to perform operations whose cost is
   linear in the length of a production, even when (with more complicated
   code) it would be possible to eliminate this cost. *)

(* -------------------------------------------------------------------------- *)

(* [search p i xs] searches the list [xs] for an element [x] that satisfies [p].
   If successful, then it returns a pair of: - [i] plus the offset of [x] in the
   list, and - the element [x]. *)

let rec search (p : 'a -> bool) (i : int) (xs : 'a list) : (int * 'a) option =
  match xs with
  | [] ->
      None
  | x :: xs ->
      if p x then Some (i, x) else search p (i+1) xs

(* -------------------------------------------------------------------------- *)

(* [find grammar symbol] looks up the definition of [symbol], which must be
   a valid nonterminal symbol, in the grammar [grammar]. *)

let find grammar symbol : rule =
  try
    StringMap.find symbol grammar.rules
  with Not_found ->
    (* This cannot happen. *)
    assert false

(* -------------------------------------------------------------------------- *)

(* [check_no_producer_attributes] checks that a producer, which represents a
   use site of an %inline symbol, does not carry any attributes. This ensures
   that we need not worry about propagating attributes through inlining. *)

let check_no_producer_attributes producer =
  match producer_attributes producer with
  | [] ->
      ()
  | (id, _payload) :: _attributes ->
      Error.error
        [position id]
        "the nonterminal symbol %s is declared %%inline.\n\
         A use of it cannot carry an attribute."
        (producer_symbol producer)

(* -------------------------------------------------------------------------- *)

(* 2015/11/18. The interaction of %prec and %inline is not documented.
   It used to be the case that we would disallow marking a production
   both %inline and %prec. Now, we allow it, but we check that (1) it
   is inlined at the last position of the host production and (2) the
   host production does not already have a %prec annotation. *)

let check_prec_inline caller producer nsuffix callee =
  callee.branch_prec_annotation |> Option.iter (fun callee_prec ->
    (* The callee has a %prec annotation. *)
    (* Check condition 1. *)
    if nsuffix > 0 then begin
      let symbol = producer_symbol producer in
      Error.error [ position callee_prec; caller.branch_position ]
        "this production carries a %%prec annotation,\n\
         and the nonterminal symbol %s is marked %%inline.\n\
         For this reason, %s can be used only in tail position."
        symbol symbol
    end;
    (* Check condition 2. *)
    caller.branch_prec_annotation |> Option.iter (fun caller_prec ->
      let symbol = producer_symbol producer in
      Error.error [ position callee_prec; position caller_prec ]
        "this production carries a %%prec annotation,\n\
         and the nonterminal symbol %s is marked %%inline.\n\
         For this reason, %s cannot be used in a production\n\
         which itself carries a %%prec annotation."
        symbol symbol
    )
  )

(* -------------------------------------------------------------------------- *)

(* [names producers] is the set of names of the producers [producers]. The
   name of a producer is the OCaml variable that is used to name its semantic
   value. *)

(* This function checks on the fly that no two producers carry the same name.
   This check should never fail if we have performed appropriate renamings.
   It is a debugging aid. *)

let names (producers : producers) : StringSet.t =
  List.fold_left (fun ids producer ->
    let id = producer_identifier producer in
    assert (not (StringSet.mem id ids));
    StringSet.add id ids
  ) StringSet.empty producers

(* -------------------------------------------------------------------------- *)

(* [new_candidate x] is a candidate fresh name, which is based on [x] in an
   unspecified way. A fairly arbitrary construction can be used here; we just
   need it to produce an infinite sequence of names, so that eventually we are
   certain to be able to escape any finite set of unavailable names. We also
   need this construction to produce reasonably concise names, as it can be
   iterated several times in practice; I have observed up to 9 iterations in
   real-world grammars. *)

(* Here, the idea is to add a suffix of the form _inlined['0'-'9']+ to the
   name [x], if it does not already include such a suffix. If [x] already
   carries such a suffix, then we increment the integer number. *)

let new_candidate x =
  let x, n = ChopInlined.chop (Lexing.from_string x) in
  Printf.sprintf "%s_inlined%d" x (n + 1)

(* [fresh names x] returns a fresh name that is not in the set [names].
   The new name is obtained by iterating [new_candidate] until we fall
   outside the set [names]. *)

let rec fresh names x =
  if StringSet.mem x names then fresh names (new_candidate x) else x

(* -------------------------------------------------------------------------- *)

(* [rename used producers] renames the producers [producers] of the inlined
   branch (the callee) if necessary to avoid a clash with the set [used] of
   the names used by the producers of the host branch (the caller). This set
   need not contain the name of the producer that is inlined away. *)

(* This function produces a pair of: 1. a substitution [phi], which represents
   the renaming that we have performed, and which must be applied to the
   semantic action of the callee; 2. the renamed [producers]. *)

let rename (used : StringSet.t) producers: Action.subst * producers =
  let phi, _used, producers =
    List.fold_left (fun (phi, used, producers) producer ->
      let x = producer_identifier producer in
      if StringSet.mem x used then
        let x' = fresh used x in
        (x, x') :: phi,
        StringSet.add x' used,
        { producer with producer_identifier = x' } :: producers
      else
        (phi, StringSet.add x used, producer :: producers)
    ) ([], used, []) producers
  in
  phi, List.rev producers

(* -------------------------------------------------------------------------- *)

(* [rename_sw_outer] transforms the keywords in the outer production (the
   caller) during inlining. It replaces [$startpos(x)] and [$endpos(x)], where
   [x] is the name of the callee, with [startpx] and [endpx], respectively. *)

let rename_sw_outer (x, startpx, endpx) (sw : sw) : sw option =
  match sw with
  | Before, _ ->
      None
  | RightNamed x', where ->
      if x' = x then
        match where with
        | WhereStart -> Some startpx
        | WhereEnd   -> Some endpx
        | WhereSymbolStart -> assert false (* has been expanded away *)
      else
        None
  | Left, _ ->
      (* [$startpos], [$endpos], and [$symbolstartpos] have been expanded away
         earlier; see [KeywordExpansion]. *)
      assert false

(* -------------------------------------------------------------------------- *)

(* [rename_sw_inner] transforms the keywords in the inner production (the callee)
   during inlining. It replaces [$endpos($0)] with [beforeendp]. *)

let rename_sw_inner beforeendp (sw : sw) : sw option =
  match sw with
  | Before, where ->
      assert (where = WhereEnd);
      Some beforeendp
  | RightNamed _, _ ->
      None
  | Left, _ ->
      (* [$startpos] and [$endpos] have been expanded away earlier; see
         [KeywordExpansion]. *)
      assert false

(* -------------------------------------------------------------------------- *)

(* [inline_branch caller site callee] inlines the branch [callee] into the
   branch [caller] at the site [site]. By convention, a site is a pair of an
   integer index -- the index [i] of the producer that must be inlined away --
   and a producer [producer] -- the producer itself. This is redundant, as
   [producer] can be recovered based on [caller] and [i], but convenient. *)

type site =
  int * producer

let inline_branch caller (i, producer : site) (callee : branch) : branch =

  (* The host branch (the caller) is divided into three sections: a prefix
     of length [nprefix], the producer that we wish to inline away, and a
     suffix of length [nsuffix]. *)

  (* Compute the length of the prefix and suffix. *)

  let nprefix = i in
  let nsuffix = List.length caller.producers - (i + 1) in

  (* Construct the prefix and suffix. *)

  let prefix = take nprefix caller.producers
  and suffix = drop (nprefix + 1) caller.producers in

  (* Apply the (undocumented) restrictions that concern the interaction
     between %prec and %inline. *)
  check_prec_inline caller producer nsuffix callee;

  (* These are the names of the producers in the host branch,
     minus the producer that is being inlined away. *)
  let used = StringSet.union (names prefix) (names suffix) in
  (* Rename the producers of this branch if they conflict with
     the name of the host's producers. *)
  let phi, inlined_producers = rename used callee.producers in

  (* After inlining, the producers are as follows. *)
  let producers = prefix @ inlined_producers @ suffix in
  (* For debugging: check that each producer carries a unique name. *)
  let (_ : StringSet.t) = names producers in

  let name = producers |> Array.of_list |> Array.map producer_identifier in

  let inlined_producers = List.length inlined_producers in

  (* Define how the start and end positions of the inner production should
     be computed once it is inlined into the outer production. These
     definitions of [startp] and [endp] are then used to transform
     [$startpos] and [$endpos] in the inner production and to transform
     [$startpos(x)] and [$endpos(x)] in the outer production. *)

  (* 2015/11/04. We ensure that positions are computed in the same manner,
     regardless of whether inlining is performed. *)

  let startp =
    if inlined_producers > 0 then
      (* If the inner production is non-epsilon, things are easy. The start
         position of the inner production is the start position of its first
         element. *)
      RightNamed name.(nprefix), WhereStart
    else if nprefix > 0 then
      (* If the inner production is epsilon, we are supposed to compute the
         end position of whatever comes in front of it. If the prefix is
         nonempty, then this is the end position of the last symbol in the
         prefix. *)
      RightNamed (name.(nprefix - 1)), WhereEnd
    else
      (* If the inner production is epsilon and the prefix is empty, then
         we need to look up the end position stored in the top stack cell.
         This is the reason why we need the keyword [$endpos($0)]. It is
         required in this case to preserve the semantics of $startpos and
         $endpos. *)
      Before, WhereEnd

    (* Note that, to contrary to intuition perhaps, we do NOT have that
       if the prefix is empty, then the start position of the inner
       production is the start production of the outer production.
       This is true only if the inner production is non-epsilon. *)

  in

  let endp =
    if inlined_producers > 0 then
      (* If the inner production is non-epsilon, things are easy: its end
         position is the end position of its last element. *)
      RightNamed (name.(nprefix + inlined_producers - 1)), WhereEnd
    else
      (* If the inner production is epsilon, then its end position is equal
         to its start position. *)
      startp

  in

  (* We must also transform [$endpos($0)] if it used by the inner
     production. It refers to the end position of the stack cell
     that comes before the inner production. So, if the prefix is
     non-empty, then it translates to the end position of the last
     element of the prefix. Otherwise, it translates to [$endpos($0)]. *)

  let beforeendp =
    if nprefix > 0 then
      RightNamed (name.(nprefix - 1)), WhereEnd
    else
      Before, WhereEnd
  in

  (* Get the name of the producer that we wish to inline away. *)

  let x = producer_identifier producer in

  (* Rename the outer and inner semantic action. *)
  let outer_action =
    Action.rename (rename_sw_outer (x, startp, endp)) [] caller.action
  and action' =
    Action.rename (rename_sw_inner beforeendp) phi callee.action
  in

  (* 2015/11/18. If the callee has a %prec annotation (which implies
     the caller does not have one, and the callee appears in tail
     position in the caller) then the annotation is inherited. This
     seems reasonable, but remains undocumented. *)
  let branch_prec_annotation =
    match callee.branch_prec_annotation with
    | (Some _) as annotation ->
        assert (caller.branch_prec_annotation = None);
        annotation
    | None ->
        caller.branch_prec_annotation
  in

  { caller with
    producers;
    action = Action.compose x action' outer_action;
    branch_prec_annotation;
  }

(* Inline a list of branches [callees] into the branch [caller] at [site]. *)

let inline_branches caller site (callees : branches) : branches =
  List.map (inline_branch caller site) callees

(* A getter and transformer for branches. *)

let get_branches rule =
  rule.branches

let transform_branches f rule =
  { rule with branches = f rule.branches }

(* Inline a grammar. The resulting grammar does not contain any definitions
   that can be inlined. *)
let inline grammar =

  let rec expand_branches expand_symbol i branches : branches =
    (* For each branch [caller] in the list [branches], *)
    branches >>= fun (caller : branch) ->
      (* Search for an inlining site in the branch [caller]. We begin the
         search at position [i], as we know that every inlining site left
         of this position has been dealt with already. *)
      let producers = drop i caller.producers in
      match search (is_inline_producer grammar) i producers with
      | None ->
          (* There is none; we are done. *)
          return caller
      | Some ((i, producer) as site) ->
          (* There is one. This is an occurrence of a nonterminal symbol
             [symbol] that is marked %inline. We look up its (expanded)
             definition (via a recursive call to [expand_symbol]), yielding
             a set of branches, which we inline into the branch [caller].
             Then, we continue looking for inlining sites. *)
          check_no_producer_attributes producer;
          let symbol = producer_symbol producer in
          expand_symbol symbol
          |> get_branches
          |> inline_branches caller site
          |> expand_branches expand_symbol i
  in

  let expand_symbol expand_symbol symbol : rule =
    find grammar symbol
    |> transform_branches (expand_branches expand_symbol 0)
  in

  let expand_symbol : Syntax.symbol -> rule =
    Memoize.String.defensive_fix expand_symbol
  in

  let expand_symbol symbol =
    try
      expand_symbol symbol
    with Memoize.String.Cycle (_, symbol) ->
      let rule = find grammar symbol in
      Error.error rule.positions
        "there is a cycle in the definition of %s." symbol
      (* TEMPORARY we can now give a better message. *)
  in

  (* If we are in Coq mode, %inline is forbidden. *)
  let _ =
    if Settings.coq then
      StringMap.iter
        (fun _ r ->
           if r.inline_flag then
             Error.error r.positions
               "%%inline is not supported by the Coq back-end.")
        grammar.rules
  in

  (* To expand a grammar, we expand all its rules and remove
     the %inline rules. *)
  let rules =
    grammar.rules
    |> StringMap.filter (fun _ r -> not r.inline_flag)
    |> StringMap.mapi (fun symbol _rule -> expand_symbol symbol) (* a little wasteful, but simple *)
  in

  let useful (k : string) : bool =
    try
      not (StringMap.find k grammar.rules).inline_flag
    with Not_found ->
      true (* could be: assert false? *)
  in

  (* Remove %on_error_reduce declarations for symbols that are expanded away,
     and warn about them, at the same time. *)
  let useful_warn (k : string) : bool =
    let u = useful k in
    if not u then
      Error.grammar_warning []
        "the declaration %%on_error_reduce %s\n\
          has no effect, since this symbol is marked %%inline and is expanded away." k;
    u
  in

  { grammar with
      rules;
      types = StringMap.filter (fun k _ -> useful k) grammar.types;
      on_error_reduce = StringMap.filter (fun k _ -> useful_warn k) grammar.on_error_reduce;
  }
