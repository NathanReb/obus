(*
 * oBus_intern.ml
 * --------------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implemtation of dbus.
 *)

(* This file contain data type that need to be shared between the
   different modules of OBus *)

open OBus_header
open OBus_info

let (&) a b = a b
let (|>) a b x = b (a x)
let (<|) a b x = a (b x)
let (>>) a b = Lwt.bind a (fun _ -> b)

module My_map(T : sig type t end) =
struct
  include Map.Make(struct type t = T.t let compare = compare end)

  let lookup key map =
    try
      Some(find key map)
    with
        Not_found -> None
end

(***** Signal matching *****)

type signal_match_rule = {
  smr_sender : string option;
  smr_path : string option;
  smr_interface : string option;
  smr_member : string option;
  smr_signature : OBus_value.signature option;
}

let signal_match r { sender = sender; typ = `Signal(path, interface, member) } signature =
  let tst m f = match m with
    | None -> true
    | Some r -> r = f
  in
  (match r.smr_sender, sender with
     | None, _ -> true
     | Some s, Some s' when s = s' -> true

     (* Here is something i am not sure, sometimes signals come with
        an sender fileds set to their connection unique name. If we
        the filter specify instead a service name, we can not match
        correctly this field. A solution can be to ask for the owner
        of the service name. *)
     | Some s, Some s' when s != "" && s.[0] <> ':' && s'.[0] = ':' -> true

     | _ -> false) &&
    (tst r.smr_path path) &&
    (tst r.smr_interface interface) &&
    (tst r.smr_member member) &&
    (tst r.smr_signature signature)

(***** Filters and connection *****)

module Serial_map = My_map(struct type t = serial end)
module Interf_map = My_map(struct type t = string end)

type body = OBus_value.sequence
type filter = OBus_header.any -> body -> unit

type buffer = string
type ptr = int

type 'a handler = 'a -> OBus_value.signature -> context -> ptr -> body Lazy.t -> unit
  (* Type of a message handler. [context] and [ptr] are used to
     unmarshal the message and [body] to see it as a dynamically typed
     value *)

and method_call_handler_result =
    (* Result of a method call handling *)
  | Mchr_no_such_method
      (* The method do not exists *)
  | Mchr_no_such_object
      (* The object do not exists *)
  | Mchr_ok of (context -> int -> unit)
      (* It know how to handle the method call, it must return a
         closure which when exectuted will unmarshal the message and
         launch a thread executing the function handling the call and
         sending the reply *)

and service_handler = method_call -> OBus_value.signature -> method_call_handler_result
  (* A service handler take the header of the call, the signature of
     the message and must lookup for if it know how to handle the
     call *)

and running_connection = {
  transport : OBus_transport.t;
  shared : bool;

  (* Unique name of the connection *)
  mutable name : string option;

  (* The server guid *)
  guid : OBus_address.guid;

  (* The ougoing thread. To send a message we just have bind the
     result of this thread to the action of sending a message. *)
  mutable outgoing : (serial * string) Lwt.t;

  filters : filter MSet.t;
  signal_handlers : (signal_match_rule * signal handler) MSet.t;

  mutable reply_handlers : (method_return handler * (exn -> unit)) Serial_map.t;
  mutable service_handlers : service_handler Interf_map.t;

  (* Handling of fatal errors *)
  on_disconnect : (exn -> unit) ref;
}

and connection_state =
  | Crashed of exn
      (* If the connection has crashed. *)
  | Running of running_connection

and connection = connection_state ref

and context = {
  buffer : buffer;
  byte_order : byte_order;
  bus_name : string option;
  connection : connection;
}

and writer = context -> ptr -> ptr
and 'a reader = context -> ptr -> ptr * 'a

type proxy = {
  proxy_connection : connection;
  proxy_service : string option;
  proxy_path : OBus_path.t;
}

open Lwt

(***** Utils ****)

let is_bus = function
  | { name = Some _ } -> true
  | _ -> false

let lwt_with_running connection f = match !connection with
  | Crashed exn -> fail exn
  | Running running -> f running

let with_running connection f = match !connection with
  | Crashed exn -> raise exn
  | Running running -> f running

let with_bus connection f = with_running connection
  (function
     | { name = Some _ } -> f ()
     | _ -> ())

let lwt_with_bus connection f = lwt_with_running connection
  (function
     | { name = Some _ } -> f ()
     | _ -> return ())

(* Do an IO operation, and verify before and after that the connection
   is OK *)
let wrap_io func connection buffer pos count =
  lwt_with_running connection
    (fun running -> func running.transport buffer pos count
       >>= fun result -> match !connection with
         | Crashed exn -> fail exn
         | _ -> return result)

let recv = wrap_io OBus_transport.recv
let send = wrap_io OBus_transport.send
let recv_exactly = wrap_io OBus_transport.recv_exactly
let send_exactly = wrap_io OBus_transport.send_exactly