(**
  Stores actions/events from zkapp commands applied to the rollup.
*)

open Core_kernel
open Mina_base
open Mina_transaction
open Sexplib.Std
open Snark_params
open Key_value_database.Monad.Ident.Let_syntax

let ok_exn x =
  let open Ppx_deriving_yojson_runtime.Result in
  match x with Ok x -> x | Error e -> failwith e

module Field = struct
  open Ppx_deriving_yojson_runtime.Result

  type t = Snark_params.Tick.Field.t [@@deriving sexp]

  let to_yojson t = `String (Tick.Field.to_string t)

  let of_yojson = function
    | `String s -> (
        try Ok (Tick.Field.of_string s)
        with _ -> Error "Field.of_yojson: bad string" )
    | _ ->
        Error "Field.of_yojson: expected string"
end

module Block_info = struct
  type t =
    { height : int
    ; state_hash : string
    ; parent_hash : string
    ; ledger_hash : string
    ; chain_status : string
    ; timestamp : int
    ; global_slot_since_hardfork : int
    ; global_slot_since_genesis : int
    ; distance_from_max_block_height : int
    }
  [@@deriving sexp, yojson]

  let dummy =
    { height = 0
    ; state_hash = ""
    ; parent_hash = ""
    ; ledger_hash = ""
    ; chain_status = ""
    ; timestamp = 0
    ; global_slot_since_hardfork = 0
    ; global_slot_since_genesis = 0
    ; distance_from_max_block_height = 1
    }
end

module Transaction_info = struct
  type t =
    { status : Transaction_status.t
    ; hash : Transaction_hash.t
    ; memo : Signed_command_memo.t
    ; authorization_kind : Account_update.Authorization_kind.t
    }
  [@@deriving sexp, yojson]
end

module Event = struct
  type t = Frozen_ledger_hash.t array [@@deriving sexp, yojson]
end

module Account_update_events = struct
  type t =
    { block_info : Block_info.t option
    ; transaction_info : Transaction_info.t option
    ; events : Event.t list
    }
  [@@deriving sexp, yojson]
end

module Action = Event

module Account_update_actions = struct
  type t =
    { block_info : Block_info.t option
    ; transaction_info : Transaction_info.t option
    ; action_state : Frozen_ledger_hash.t Pickles_types.Vector.Vector_5.t
    ; account_update_id : int
    ; actions : Action.t list
    }
  [@@deriving sexp, yojson]
end

module Archive = struct
  type t = Kvdb.t

  let create ~kvdb : t = kvdb

  let serialize_key account_id =
    Bigstring.of_string
      ( Signature_lib.Public_key.Compressed.to_base58_check
          (Account_id.public_key account_id)
      ^ "-"
      ^ Token_id.to_string (Account_id.token_id account_id) )

  let query_events t account_id =
    let%bind events = Kvdb.get t ~key:(EVENTS account_id) in
    let events =
      Option.value ~default:"[]" @@ Option.map ~f:Bigstring.to_string events
    in
    List.map
      ~f:(fun event -> ok_exn @@ Account_update_events.of_yojson event)
      Yojson.Safe.(Util.to_list @@ from_string events)

  let query_actions t account_id =
    let%bind actions = Kvdb.get t ~key:(ACTIONS account_id) in
    let actions =
      Option.value ~default:"[]" @@ Option.map ~f:Bigstring.to_string actions
    in
    List.map
      ~f:(fun event -> ok_exn @@ Account_update_actions.of_yojson event)
      Yojson.Safe.(Util.to_list @@ from_string actions)

  let store_events t account_id events =
    let events =
      Yojson.Safe.to_string
      @@ `List (List.map ~f:Account_update_events.to_yojson events)
    in
    let%bind () =
      Kvdb.set t ~key:(EVENTS account_id) ~data:(Bigstring.of_string events)
    in
    ()

  let store_actions t account_id actions =
    let actions =
      Yojson.Safe.to_string
      @@ `List (List.map ~f:Account_update_actions.to_yojson actions)
    in
    let%bind () =
      Kvdb.set t ~key:(ACTIONS account_id) ~data:(Bigstring.of_string actions)
    in
    ()

  let add_actions t (account_update : Account_update.t) transaction_info
      (account : Account.t) =
    match account_update.body.actions with
    | [] ->
        ()
    | actions ->
        let zkapp : Zkapp_account.t = Option.value_exn account.zkapp in
        let action =
          { Account_update_actions.block_info = Some Block_info.dummy
          ; transaction_info
          ; action_state = zkapp.action_state
          ; account_update_id = 0
          ; actions
          }
        in
        let account : Account_id.t =
          Account_id.create account_update.body.public_key
            account_update.body.token_id
        in
        let previous = query_actions t account in
        store_actions t account (action :: previous)

  let add_events t (account_update : Account_update.t) transaction_info =
    match account_update.body.events with
    | [] ->
        ()
    | events ->
        let event =
          { Account_update_events.block_info = Some Block_info.dummy
          ; transaction_info
          ; events
          }
        in
        let account : Account_id.t =
          Account_id.create account_update.body.public_key
            account_update.body.token_id
        in
        let previous = query_events t account in
        store_events t account (event :: previous)

  let add_account_update t (account_update : Account_update.t) account
      transaction_info =
    add_actions t account_update transaction_info account ;
    add_events t account_update transaction_info

  let get_actions t account_id from =
    let open Account_update_actions in
    let rec filter_start from actions =
      match actions with
      | [] ->
          []
      | ({ action_state; _ } as action) :: rest
        when Stdlib.(Pickles_types.Vector.nth action_state 0 = from) ->
          action :: rest
      | _ :: rest ->
          filter_start from rest
    in
    let all = List.rev @@ query_actions t account_id in
    (* If the `from` wasn't found return all *)
    (* Weird, but it's the same way in archive node *)
    match filter_start from all with [] -> all | actions -> actions

  let get_events t account_id = List.rev @@ query_events t account_id
end

include Archive
