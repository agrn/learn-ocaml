open Lwt
open Learnocaml_data

let ( / ) dir f = if dir = "" then f else Filename.concat dir f

module J = Json_encoding

module Json_codec = struct
  let decode enc s =
    (match s with
     | "" -> `O []
     | s -> Ezjsonm.from_string s)
    |> J.destruct enc

  let encode ?minify enc x =
    match J.construct enc x with
    | `A _ | `O _ as json -> Ezjsonm.to_string ?minify json
    | `Null -> ""
    | _ -> assert false
end

module type IndexRW = sig
  type t

  val init : unit -> t
  val read : string -> (string -> 'a) -> 'a Lwt.t
  val write : t -> string -> ('a -> string) -> 'a -> unit Lwt.t
end

module IndexFile: IndexRW = struct
  type t = Lwt_mutex.t

  (* Unlocked by default *)
  let init = Lwt_mutex.create

  let read filename parse =
    Lwt_io.open_file ~mode:Lwt_io.Input filename >>= fun channel ->
    Lwt_io.read channel >>= fun data ->
    Lwt_io.close channel >>= fun () ->
    Lwt.return @@ parse data

  let write mutex filename serialise data =
    Lwt_mutex.lock mutex >>= fun () ->
    Lwt_io.open_file ~mode:Lwt_io.Output filename >>= fun channel ->
    Lwt_io.write channel (serialise data) >>= fun () ->
    Lwt_io.close channel >>= fun () ->
    Lwt.return @@ Lwt_mutex.unlock mutex
end

module BaseTokenIndex (RW: IndexRW) = struct
  let rw = RW.init ()
  let file = "token.json"

  let enc = J.list Token.enc

  let parse = Json_codec.decode enc
  let serialise_str = Json_codec.encode ?minify:(Some(false)) J.(list string)
  let serialise = Json_codec.encode ?minify:(Some(false)) enc

  let create_index sync_dir =
    let found_indexes =
      let rec scan f d acc =
        let rec aux s acc =
          Lwt.catch (fun () ->
              Lwt_stream.get s >>= function
              | Some ("." | "..") -> aux s acc
              | Some x -> scan f (d / x) acc >>= aux s
              | None -> Lwt.return acc)
          @@ function
          | Unix.Unix_error (Unix.ENOTDIR, _, _) -> f d acc
          | Unix.Unix_error _ -> Lwt.return acc
          | e -> Lwt.fail e
        in
        aux (Lwt_unix.files_of_directory (sync_dir / d)) acc
      in
      scan (fun d acc ->
          let d =
            if Filename.basename d = "save.json" then Filename.dirname d
            else d
          in
          let stok = String.map (function '/' | '\\' -> '-' | c -> c) d in
          if Token.check stok then
            Lwt.return (stok :: acc)
          else
            Lwt.return acc
        ) "" [] in
    Lwt_io.printl "Regenerating the token index..." >>= fun () ->
    found_indexes >>= RW.write rw (sync_dir / file) serialise_str

  let get_file sync_dir name =
    let filename = (sync_dir / name) in
    let create () =
          create_index sync_dir >>= fun () ->
          RW.read filename parse in
    if Sys.file_exists filename then
      Lwt.catch
        (fun () -> RW.read filename parse)
        (fun _exn ->
           (* Note: this error handler may be adapted later to be more conservative?
              it does not matter now as sync/token.json is not a critical file, and
              can be regenerated. *)
           create ())
    else
      create ()

  let get_tokens sync_dir =
    get_file sync_dir file

  let add_token sync_dir token =
    get_tokens sync_dir >>= fun tokens ->
    RW.write rw (sync_dir / file) serialise (token :: tokens)
end

module TokenIndex = BaseTokenIndex (IndexFile)
