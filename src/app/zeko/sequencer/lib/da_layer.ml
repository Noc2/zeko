open Core_kernel
open Mina_base
open Async

module Config = struct
  type t = { da_contract_address : string option }
end

let command_to_yojson command =
  match command with
  | User_command.Signed_command signed_command ->
      `Assoc
        [ ("commandType", `Int 0)
        ; ("data", `String (Signed_command.to_base64 signed_command))
        ]
  | User_command.Zkapp_command zkapp_command ->
      `Assoc
        [ ("commandType", `Int 1)
        ; ("data", `String (Zkapp_command.to_base64 zkapp_command))
        ]

let post_batch (config : Config.t) ~commands ~batch_id ~previous_batch_id =
  Utils.retry
    ~f:(fun () ->
      match config.da_contract_address with
      | None ->
          print_endline
            "No da contract address provided. Skipping batch posting" ;
          return (Ok ())
      | Some da_contract_address ->
          let payload =
            Yojson.to_string
              (`Assoc
                [ ("address", `String da_contract_address)
                ; ("id", `String batch_id)
                ; ("previousId", `String previous_batch_id)
                ; ("commands", `List (List.map commands ~f:command_to_yojson))
                ] )
          in
          let postBatchCmd =
            match Sys.getenv "DA_POST_BATCH" with
            | Some cmd ->
                cmd
            | None ->
                "exec $cd ../da-layer && npx hardhat run scripts/postBatch.ts"
          in
          let stdin = Core.Unix.open_process_out postBatchCmd in
          let pid = UnixLabels.process_out_pid stdin in
          Out_channel.output_string stdin payload ;
          Out_channel.close stdin ;
          Unix.waitpid (Pid.of_int pid) )
    ()

let get_batches (config : Config.t) ~to_ =
  match config.da_contract_address with
  | None ->
      print_endline "No da contract address provided. Skipping bootstrapping" ;
      return []
  | Some da_contract_address ->
      let payload =
        Yojson.to_string
          (`Assoc
            [ ("address", `String da_contract_address); ("to", `String to_) ] )
      in
      let getBatchesCmd =
        match Sys.getenv "DA_GET_BATCHES" with
        | Some cmd ->
            cmd
        | None ->
            "exec $cd ../da-layer && npx hardhat run scripts/getBatches.ts"
      in
      let stdout, stdin = Core.Unix.open_process getBatchesCmd in
      let pid = UnixLabels.process_pid (stdout, stdin) in
      Out_channel.output_string stdin payload ;
      Out_channel.close stdin ;
      let result = In_channel.input_all stdout in
      In_channel.close stdout ;
      let%bind () = Unix.waitpid_exn (Pid.of_int pid) in
      let commands =
        Yojson.Safe.Util.(
          to_list @@ Yojson.Safe.from_string result
          |> List.map ~f:(fun json ->
                 match member "commandType" json |> to_int with
                 | 0 ->
                     let data = member "data" json |> to_string in
                     let signed_command =
                       Signed_command.of_base64 data |> ok_exn
                     in
                     User_command.Signed_command signed_command
                 | 1 ->
                     let data = member "data" json |> to_string in
                     let zkapp_command =
                       Zkapp_command.of_base64 data |> ok_exn
                     in
                     User_command.Zkapp_command zkapp_command
                 | _ ->
                     failwith "Unknown command type" ))
      in
      return commands
