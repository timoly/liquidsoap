(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2013 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

open Source

class rms ~kind source =
object (self)
  inherit operator kind [source] ~name:"rms" as super

  method stype = source#stype
  method is_ready = source#is_ready
  method remaining = source#remaining
  method abort_track = source#abort_track

  val mutable volume = 0.

  val m = Mutex.create ()

  method rms =
    Tutils.mutexify m
      (fun () -> volume) ()

  method private get_frame buf =
    let offset = AFrame.position buf in
    source#get buf;
    let rms = AFrame.rms buf offset (AFrame.position buf - offset) in
    let channels = Array.length rms in
    Tutils.mutexify m
      (fun () ->
        volume <- 0.;
        for i = 0 to channels - 1 do
          volume <- volume +. rms.(i)
        done;
        volume <- volume /. (float channels)) ()
end

let () =
  let format = Lang.any_fixed_with ~audio:1 () in
  let k = Lang.kind_type_of_kind_format ~fresh:1 format in
  let return_t =
    Lang.product_t
      (Lang.fun_t [] Lang.float_t)
      (Lang.source_t k)
  in
  Lang.add_builtin "rms"
    ~category:(Lang.string_of_category Lang.Visualization)
    ~descr:"Get current audio RMS volume of the source. \
            Returns a pair @(f,s)@ where s is a new source and \
            @f@ is a function of type @() -> float@ and \
            returns the current RMS of the source."
    [ "id",Lang.string_t,Some (Lang.string ""),
      Some "Force the value of the source ID.";
      "", Lang.source_t k, None, None ] return_t
    (fun p t ->
      let f v = List.assoc v p in
      let src = Lang.to_source (f "") in
      let id = Lang.to_string (f "id") in
      let (_,t) = Lang.of_product_t t in
      let kind = Lang.frame_kind_of_kind_type (Lang.of_source_t t) in
      let s = new rms ~kind src in
      if id <> "" then s#set_id id;
      let f =
        Lang.val_fun [] ~ret_t:Lang.float_t
          (fun p t -> Lang.float s#rms)
      in
      Lang.product f (Lang.source (s :> Source.source)))
