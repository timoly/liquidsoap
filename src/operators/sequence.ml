(*****************************************************************************

  Liquidsoap, a programmable stream generator.
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

(** Given a list of [sources], play one track from each of the first
  * sources, then loop on the last one. Optionally, merge tracks when
  * advancing in the sequence. The [merge] flag will *not* merge tracks
  * while looping on the last source -- this behavior would not be suited
  * to the current use of [sequence] in transitions. *)
class sequence ~kind ?(merge=false) sources =
object (self)
  inherit operator ~name:"sequence" kind sources as super

  val mutable sources = sources
  initializer assert (sources <> [])

  method stype = (List.hd (List.rev sources))#stype

  method private wake_up activation =
    List.iter
      (fun s -> (s:>source)#get_ready ((self:>source)::activation))
      sources

  method private sleep =
    List.iter (fun s -> (s:>source)#leave (self:>source)) sources

  (** When head_ready is true, it must be that:
    *  - (List.hd sources)#is_ready
    *  - or we have started playing a track of (List.hd sources)
    *    and that track has not ended yet.
    * In case the head source becomes unavailable before its end of track,
    * head_ready keeps the sequence operator available, so that its #get_frame
    * can be called to properly end the track and cleanup the source if needed.
    * If instead the operator had become unavailable then source#get would have
    * inserted an end of track automatically instead of calling #get_frame. *)
  val mutable head_ready = false

  method is_ready = head_ready || List.exists (fun s -> s#is_ready) sources

  method remaining =
    if merge then
      let (+) a b = if a<0 || b<0 then -1 else a+b in
        List.fold_left (+) 0 (List.map (fun s -> s#remaining) sources)
    else
      (List.hd sources)#remaining

  method abort_track =
    if merge then begin
      match List.rev sources with
        | [] -> assert false
        | hd::tl ->
            sources <- [hd] ;
            List.iter (fun (s:source) -> s#leave (self:>source)) tl
    end ;
    (List.hd sources)#abort_track

  method private get_frame buf =
    if head_ready then begin
      let hd = List.hd sources in
        hd#get buf ;
        if Frame.is_partial buf then begin
          head_ready <- false ;
          if List.length sources > 1 then begin
            hd#leave (self:>source) ;
            sources <- List.tl sources ;
            if merge && self#is_ready then
              let pos = Frame.position buf in
                self#get_frame buf ;
                Frame.set_breaks buf
                  (Utils.remove_one ((=) pos) (Frame.breaks buf))
          end
        end
    end else begin
      match sources with
        | a::(_::_ as tl) ->
            if a#is_ready then
              head_ready <- true
            else begin
              a#leave (self:>source) ;
              sources <- tl
            end ;
            self#get_frame buf
        | [a] ->
            assert (a#is_ready) ; (* Our #is_ready ensures that. *)
            head_ready <- true ;
            self#get_frame buf
        | [] -> assert false
    end

end

class merge_tracks ~kind source =
object (self)

  inherit operator ~name:"sequence" kind [source] as super

  method stype = source#stype
  method is_ready = source#is_ready
  method abort_track = source#abort_track
  method remaining = -1

  method private get_frame buf =
    source#get buf ;
    if Frame.is_partial buf && source#is_ready then
      let pos = Frame.position buf in
        self#log#f 4 "End of track: merging." ;
        self#get_frame buf ;
        Frame.set_breaks buf
          (Utils.remove_one ((=) pos) (Frame.breaks buf))

end

let () =
  let k = Lang.univ_t 1 in
  Lang.add_operator "sequence"
    [ "merge", Lang.bool_t, Some (Lang.bool false),
      Some "Merge tracks when advancing from one source to the next one. \
            This will NOT merge consecutive tracks from the last source; \
            see merge_tracks() if you need that too." ;
      "", Lang.list_t (Lang.source_t k), None, None ]
    ~category:Lang.TrackProcessing
    ~descr:"Play only one track of every successive source, \
            except for the last one which is played as much as available. \
            Sources are released after being used, allowing them to shutdown \
            cleanly and free their resources."
    ~kind:(Lang.Unconstrained k)
    (fun p kind ->
       new sequence ~kind
         ~merge:(Lang.to_bool (List.assoc "merge" p))
         (Lang.to_source_list (List.assoc "" p)))

let () =
  let k = Lang.univ_t 1 in
  Lang.add_operator "merge_tracks"
    [ "", Lang.source_t k, None, None ]
    ~category:Lang.TrackProcessing
    ~descr:"Merge consecutive tracks from the input source."
    ~kind:(Lang.Unconstrained k)
    (fun p kind ->
       new merge_tracks ~kind (Lang.to_source (List.assoc "" p)))
