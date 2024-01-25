open Core
open Async
open Mina_ledger
open Mina_base
module Graphql_cohttp_async =
  Init.Graphql_internal.Make (Graphql_async.Schema) (Cohttp_async.Io)
    (Cohttp_async.Body)

let run port db_dir genesis_account () =
  let db =
    ref
    @@ Ledger.Db.create ~directory_name:db_dir
         ~depth:Gql.constraint_constants.ledger_depth ()
  in

  ( if Option.is_some genesis_account then
    let account_id =
      Account_id.create
        (Signature_lib.Public_key.Compressed.of_base58_check_exn
           (Option.value_exn genesis_account) )
        Token_id.default
    in
    let account =
      Account.create account_id
        (Currency.Balance.of_uint64
           (Unsigned.UInt64.of_int64 1_000_000_000_000L) )
    in
    ( Ledger.Db.get_or_create_account !db account_id account
      : ([ `Added | `Existed ] * Ledger.Db.Location.t) Or_error.t )
    |> ignore ) ;

  let graphql_callback =
    Graphql_cohttp_async.make_callback
      (fun ~with_seq_no:_ _req -> !db)
      Gql.schema
  in
  let () =
    Cohttp_async.Server.create_expert
      ~on_handler_error:
        (`Call
          (fun _ exn ->
            print_endline "Unhandled exception" ;
            print_endline (Exn.to_string exn) ) )
      (Async.Tcp.Where_to_listen.of_port port)
      (fun ~body _sock req ->
        let headers = Cohttp.Request.headers req in
        match Cohttp.Header.get headers "Connection" with
        | Some "Upgrade" ->
            Graphql_cohttp_async.respond_string ~status:`Forbidden
              ~body:"Websocket not supported" ()
        | _ ->
            graphql_callback () req body )
    |> Deferred.ignore_m |> don't_wait_for
  in
  print_endline ("Local network listening on port " ^ Int.to_string port) ;
  never_returns (Async.Scheduler.go ())

let () =
  Command.basic ~summary:"Local network"
    (let%map_open.Command port =
       flag "-p" (optional_with_default 8080 int) ~doc:"int Port to listen on"
     and genesis_account =
       flag "--genesis-account" (optional string)
         ~doc:"string Optional public key of genesis account"
     and db_dir =
       flag "--db-dir"
         (optional_with_default "l1_db" string)
         ~doc:"string Directory to store the database"
     in
     run port db_dir genesis_account )
  |> Command_unix.run
