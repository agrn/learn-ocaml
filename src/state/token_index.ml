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

module BaseMoodleIndex (RW: IndexRW) = struct
  let rw = RW.init ()
  let file = "moodle_user.json"

  let enc = J.assoc Token.enc

  let parse = Json_codec.decode enc
  let serialise = Json_codec.encode ?minify:(Some(false)) enc

  let create_index sync_dir =
    RW.write rw (sync_dir / file) serialise []

  let get_users sync_dir =
    Lwt.catch
      (fun () -> RW.read (sync_dir / file) parse)
      (fun _exn -> Lwt.return [])

  let user_exists sync_dir id =
    get_users sync_dir >|=
    List.exists (fun (rid, _token) -> rid = id)

  let add_user sync_dir id token =
    get_users sync_dir >>= fun users ->
    if List.exists (fun (rid, _token) -> rid = id) users then
      Lwt.return ()
    else
      let users = (id, token) :: users in
      RW.write rw (sync_dir / file) serialise users

  let get_user_token sync_dir id =
    get_users sync_dir >|= fun users ->
    List.find (fun (rid, _token) -> rid = id) users
    |> snd
end

module MoodleIndex = BaseMoodleIndex (IndexFile)

module BaseOauthIndex (RW: IndexRW) = struct
  let rw = RW.init ()
  let file = "oauth.json"

  let enc = J.(assoc (list string))

  let parse = Json_codec.decode enc
  let serialise = Json_codec.encode ?minify:(Some(false)) enc

   (* Copyright https://github.com/astrada/gapi-ocaml
      Return a secret hexa encoded *)
  let gen_secret len =
    let hexa_encode s =
      let transform = Cryptokit.Hexa.encode () in
      transform#put_string s;
      transform#finish;
      transform#get_string
    in
    let secret = hexa_encode @@ Cryptokit.Random.string Cryptokit.Random.secure_rng len in
    Printf.printf "Auto-generated secret : %s\n" secret;
    secret

  let create_index sync_dir =
    let secret = gen_secret 32 in
    RW.write rw (sync_dir / file) serialise [(secret, [])] >|= fun () ->
    secret

  let get_first_oauth sync_dir =
    let create () =
      create_index sync_dir >|= fun secret ->
      (secret, []) in
    Lwt.catch
      (fun () ->
         RW.read (sync_dir / file) parse >>= function
         | oauth :: _ -> Lwt.return oauth
         | [] -> create ())
      (fun _exn -> create ())

  let get_current_secret sync_dir =
    get_first_oauth sync_dir >|= fun (secret, _nonces) ->
    secret

  let purge sync_dir =
    get_first_oauth sync_dir >>= fun oauth ->
    RW.write rw (sync_dir / file) serialise [oauth]

  let add_nonce sync_dir nonce =
    RW.read (sync_dir / file) parse >>= fun oauth ->
    let oauth =
      match oauth with
      | (secret, nonces) :: r -> (secret, nonce :: nonces) :: r
      | [] -> [(gen_secret 32, [nonce])] in
    RW.write rw (sync_dir / file) serialise oauth

  let check_nonce sync_dir nonce =
    get_first_oauth sync_dir >|= fun (_secret, nonces) ->
    List.exists ((=) nonce) nonces
end

module OauthIndex = BaseOauthIndex (IndexFile)
