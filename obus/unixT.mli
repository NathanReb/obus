(*
 * unixT.mli
 * ---------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implemtation of dbus.
 *)

(** Unix transport for OBus *)

val make_transport : Unix.file_descr -> Transport.t