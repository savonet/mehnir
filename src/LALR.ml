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

(* This module constructs an LALR automaton for the grammar described by the
   module [Grammar]. *)

(* In LALR mode, two LR(1) states are merged as soon as they have the same
   LR(0) core. *)

open Grammar

type lr1state =
  Lr0.lr1state

module Run () = struct

(* -------------------------------------------------------------------------- *)

(* Since the LALR automaton has exactly the same states as the LR(0)
   automaton, up to lookahead information, we can use the same state
   numbers. *)

type node =
  int

let n =
  Lr0.n

(* Each node is associated with a state. This state can change during
   construction as nodes are merged. *)

let states : lr1state option array =
  Array.make n None

(* -------------------------------------------------------------------------- *)

(* Output debugging information if [--follow-construction] is enabled. *)

let print_state (state : lr1state) =
  Lr0.print_closure "" state

let print_ostate (ostate : lr1state option) =
  match ostate with
  | None ->
      "<none>"
  | Some state ->
      print_state state

let follow_transition
  (source : node) (symbol : Symbol.t) (target : node) (state : lr1state)
=
  if Settings.follow then
    Printf.fprintf stderr
      "Examining transition out of state %d along symbol %s to state %d.\n\
       Proposed target state:\n%s"
      source
      (Symbol.print symbol)
      target
      (print_state state)

let follow_state (msg : string) (node : node) (print : bool) =
  if Settings.follow then
    Printf.fprintf stderr
      "%s: %d.\n%s\n"
      msg
      node
      (if print then print_ostate states.(node) else "")

(* -------------------------------------------------------------------------- *)

(* A queue of pending nodes, whose outgoing transitions must be reexamined. *)

(* Invariant: if a node is in the queue, then [states.(node)] is not [None]. *)

let queue : node Queue.t =
  Queue.create()

(* The Boolean array [queued] keeps track of which nodes are in the queue and
   allows us to avoid enqueueing a node when it is already in the queue. *)

let queued : bool array =
  Array.make n false

let schedule node =
  if not queued.(node) then begin
    queued.(node) <- true;
    Queue.add node queue
  end

(* -------------------------------------------------------------------------- *)

(* [examine] examines a node that has just been taken out of the queue. Its
   outgoing transitions are inspected. If a successor node is newly discovered
   or updated, then it is scheduled or rescheduled for examination. *)

let rec examine node =
  (* Fetch the LR(1) state currently associated with this node. *)
  let state : lr1state = Option.force states.(node) in
  (* Inspect the node's outgoing transitions. *)
  SymbolMap.iter (fun symbol (successor_node : node) ->
    let successor_state : lr1state = Lr0.transition symbol state in
    follow_transition node symbol successor_node successor_state;
    inspect successor_node successor_state
  ) (Lr0.outgoing_edges node)

(* [inspect node state] ensures that the state currently associated with
   [node] is at least [state]. If this requires an update of [states.(node)],
   then [node] is (re)scheduled for examination. *)

and inspect node state =
  match states.(node) with
  | None ->
      (* [node] is newly discovered. *)
      follow_state "Target state is newly discovered" node true;
      states.(node) <- Some state;
      schedule node
  | Some current ->
      (* [node] has been discovered earlier. *)
      if Lr0.subsume state current then begin
        (* It is unaffected. *)
        follow_state "Target state is unaffected" node false
      end
      else begin
        (* It is affected and must itself be scheduled. *)
        states.(node) <- Some (Lr0.union state current);
        follow_state "Growing existing state" node true;
        schedule node
      end

(* -------------------------------------------------------------------------- *)

(* The actual construction process. *)

(* Populate the queue with the entry nodes. *)

let () =
  ProductionMap.iter (fun _prod node ->
    states.(node) <- Some (Lr0.start node);
    schedule node
  ) Lr0.entry

(* As a long as the queue is nonempty, examine the nodes in it. *)

let () =
  try
    while true do
      let node = Queue.take queue in
      queued.(node) <- false;
      examine node
    done
  with Queue.Empty ->
    ()

(* -------------------------------------------------------------------------- *)

(* Expose the mapping of nodes to LR(1) states. *)

let states : lr1state array =
  Array.map Option.force states

let state : node -> lr1state =
  Array.get states

(* -------------------------------------------------------------------------- *)

(* Expose the entry nodes and transitions of the LALR automaton. *)

(* Because we re-use LR(0) node numbers, these are exactly the same as those
   of the LR(0) automaton! *)

let entry : node ProductionMap.t =
  Lr0.entry

let transitions : node -> node SymbolMap.t =
  Lr0.outgoing_edges

(* -------------------------------------------------------------------------- *)

(* Expose the bijection between nodes and numbers. *)

let number (i : node) : int =
  i

let node (i : int) : node =
  i

(* -------------------------------------------------------------------------- *)

end (* Run *)
