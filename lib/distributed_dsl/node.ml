open Core_kernel
open Async_kernel

module type Peer_intf = sig
  type t [@@deriving eq, hash, compare, sexp]
  include Hashable.S with type t := t
end

module type Transport_intf = sig
  type t
  type message
  type peer

  val send : t -> recipient:peer -> message -> unit Or_error.t Deferred.t
  val listen : t -> me:peer -> message Linear_pipe.Reader.t
end

module type Timer_intf = sig
  type t
  type tok [@@deriving eq]
  val wait : t -> Time.Span.t -> tok * [`Cancelled | `Finished] Deferred.t
  (* No-ops if already cancelled *)
  val cancel : t -> tok -> unit
end

module type S = sig
  type message
  type state
  type transport
  type peer
  module Message_label : Hashable.S
  module Timer_label : Hashable.S
  module Condition_label : Hashable.S
  module Timer : Timer_intf
  module Identifier : Hashable.S with type t := peer

  type 'a condition = state -> 'a option

  type 'a message_condition = message -> 'a condition

  type 'a transition = t -> 'a -> state Deferred.t
  and t

  type handle_command
  type message_command

  val on
    : Condition_label.t
    -> 'a condition
    -> f:'a transition
    -> handle_command

  val msg
    : Message_label.t
    -> 'a message_condition
    -> f:'a transition
    -> message_command

  val cancel
    : t
    -> ?tok:Timer.tok option
    -> Timer_label.t
    -> unit

  val timeout
    : t
    -> Timer_label.t
    -> Time.Span.t
    -> f:state transition
    -> Timer.tok

  val timeout'
    : t
    -> Timer_label.t
    -> Time.Span.t
    -> f:state transition
    -> unit

  val next_ready : t -> unit Deferred.t
  val is_ready : t -> bool

  val make_node 
    : transport : transport
    -> parent_log : Logger.t
    -> me : peer
    -> messages : message Linear_pipe.Reader.t
    -> ?parent : t
    -> initial_state : state
    -> timer : Timer.t
    -> message_command list 
    -> handle_command list 
    -> t

  val step : t -> t Deferred.t

  val ident : t -> peer
  val state : t -> state

  val send : t -> recipient:peer -> message -> unit Or_error.t Deferred.t
  val send_exn : t -> recipient:peer -> message -> unit Deferred.t
  val send_multi : t -> recipients:peer list -> message -> unit Or_error.t list Deferred.t
  val send_multi_exn : t -> recipients:peer list -> message -> unit Deferred.t
end

module type F =
  functor 
    (State : sig type t [@@deriving eq, sexp] end)
    (Message : sig type t end)
    (Peer : Peer_intf)
    (Timer : Timer_intf)
    (Message_label : sig 
       type label [@@deriving enum, sexp]
       include Hashable.S with type t = label
     end)
    (Timer_label : sig 
       type label [@@deriving enum, sexp]
       include Hashable.S with type t = label
     end)
    (Condition_label : sig 
       type label [@@deriving enum, sexp]
       include Hashable.S with type t = label
     end)
    (Transport : Transport_intf with type message := Message.t
                                 and type peer := Peer.t)
    -> S with type message := Message.t
          and type state := State.t
          and type transport := Transport.t
          and type peer := Peer.t
          and module Message_label := Message_label
          and module Timer_label := Timer_label
          and module Condition_label := Condition_label
          and module Timer := Timer

module Make 
    (State : sig type t [@@deriving eq, sexp] end)
    (Message : sig type t end)
    (Peer : Peer_intf)
    (Timer : Timer_intf)
    (Message_label : sig 
       type label [@@deriving enum, sexp]
       include Hashable.S with type t = label
     end)
    (Timer_label : sig 
       type label [@@deriving enum, sexp]
       include Hashable.S with type t = label
     end)
    (Condition_label : sig 
       type label [@@deriving enum, sexp]
       include Hashable.S with type t = label
     end)
    (Transport : Transport_intf with type message := Message.t 
                                 and type peer := Peer.t)
= struct
    module Identifier = Peer

    type condition = State.t -> bool

    type message_condition = Message.t -> condition

    type transition = t -> State.t -> State.t Deferred.t
    and message_transition = t -> Message.t -> State.t -> State.t Deferred.t
    and handle_command = H : Condition_label.t * condition * transition -> handle_command
    and message_command = M : Message_label.t * message_condition * message_transition -> message_command
    and t =
      { state : State.t
      ; last_state : State.t option
      ; conditions : handle_command Condition_label.Table.t
      ; message_pipe : Message.t Linear_pipe.Reader.t
      ; message_handlers : message_command Message_label.Table.t
      ; triggered_timers_r : transition Linear_pipe.Reader.t
      ; triggered_timers_w : transition Linear_pipe.Writer.t
      ; timer : Timer.t
      ; timers : Timer.tok list Timer_label.Table.t
      ; ident : Identifier.t
      ; transport : Transport.t
      ; logger : Logger.t
      }

    let on label condition ~f =
      (label, condition, f)

    let msg label condition ~f =
      (label, condition, f)

    let add_back_timers t ~key ~data =
      if List.length data > 0 then
        let _ = Timer_label.Table.set t.timers ~key ~data in
        ()
      else
        Timer_label.Table.remove t.timers key

    let cancel t ?tok:(tok=None) label =
      let l = Timer_label.Table.find_multi t.timers label in
      let (to_cancel, to_put_back) =
        List.partition_map l ~f:(fun tok' ->
          match tok with
          | None -> `Fst tok'
          | Some tok ->
              if tok = tok' then
                `Fst tok'
              else
                `Snd tok'
        )
      in
      List.iter to_cancel ~f:(fun tok' ->
        Timer.cancel t.timer tok'
      );
      add_back_timers t ~key:label ~data:to_put_back

    let timeout t label ts ~(f:transition) =
      let remove_tok tok =
        let l = Timer_label.Table.find_multi t.timers label in
        let l' = List.filter l ~f:(fun tok' -> not (Timer.equal_tok tok tok')) in
        add_back_timers t ~key:label ~data:l'
      in

      let tok, waited = Timer.wait t.timer ts in
      let () = Timer_label.Table.add_multi t.timers ~key:label ~data:tok in
      don't_wait_for begin
        match%map waited with
        | `Cancelled ->
          remove_tok tok
        | `Finished ->
          remove_tok tok;
          Linear_pipe.write_or_exn ~capacity:1024 t.triggered_timers_w t.triggered_timers_r f;
      end;
      tok

    let timeout' t label ts ~f =
      let _ = timeout t label ts ~f in
      ()

    let state_changed t =
      not (Option.equal State.equal (Some t.state) t.last_state)

    let next_ready t : unit Deferred.t =
      let ready p = Linear_pipe.values_available p >>= (Fn.const (return ())) in
      Deferred.any
      [ ready t.message_pipe
      ; ready t.triggered_timers_r
      ; if state_changed t then
          return ()
        else
          Deferred.never ()
      ]

    let is_ready t : bool =
      let b = Linear_pipe.peek t.message_pipe |> Option.is_some ||
              Linear_pipe.peek t.triggered_timers_r |> Option.is_some ||
              state_changed t
      in
      b

    let make_node ~transport ~parent_log ~me ~messages ?parent ~initial_state ~timer message_conditions handle_conditions =
      let logger = Logger.child parent_log (Printf.sprintf !"dsl_node:%{sexp:Peer.t}" me) in
      let conditions = Condition_label.Table.create () in
      List.iter handle_conditions ~f:(fun (l, c, h) ->
        match Condition_label.Table.add conditions ~key:l ~data:(H (l,c,h)) with
        | `Duplicate ->
            failwithf "You specified the same condition twice! %s"
              (Condition_label.sexp_of_label l |> Sexp.to_string_hum) ()
        | `Ok -> ()
      );
      let message_handlers = Message_label.Table.create () in
      List.iter message_conditions ~f:(fun (l, c, h) ->
        match Message_label.Table.add message_handlers ~key:l ~data:(M (l,c,h)) with
        | `Duplicate ->
            failwithf "You specified the same message handler twice! %s"
              (Message_label.sexp_of_label l |> Sexp.to_string_hum) ()
        | `Ok -> ()
      );
      let timers = Timer_label.Table.create () in
      let triggered_timers_r, triggered_timers_w = Linear_pipe.create () in
      let t =
        { state = initial_state
        ; last_state = None
        ; conditions
        ; message_pipe = messages
        ; message_handlers
        ; triggered_timers_r
        ; triggered_timers_w
        ; timer
        ; timers
        ; ident = me
        ; transport
        ; logger
        }
      in
      t

    let with_new_state t state : t =
      { t with last_state = Some (t.state)
      ; state
      }

    let step t : t Deferred.t =
      match (
        state_changed t,
        Linear_pipe.peek t.triggered_timers_r,
        Linear_pipe.peek t.message_pipe
      ) with
      | true, _, _ ->
          let checks = Condition_label.Table.to_alist t.conditions in
          let matches = List.filter checks ~f:(fun (_, H (_, cond, _)) ->
            cond t.state
          ) in
          (match matches with
          | [] ->
              return (with_new_state t (t.state))
          | (label,H (_, _,transition))::[] ->
              let%map t' = (transition t t.state) >>| (with_new_state t) in
              Logger.debug t.logger !"Making transition from %{sexp:State.t} to %{sexp:State.t} at %{sexp:Peer.t} label: %{sexp:Condition_label.label}\n%!" t.state t'.state t.ident label;
              t'
          | _::_::xs as l ->
            failwithf "Multiple conditions matched current state: %s"
              (List.map l ~f:(fun (label, _) -> label) |> List.sexp_of_t Condition_label.sexp_of_label |> Sexp.to_string_hum) ())
      | false, Some transition, _ ->
          let _ = Linear_pipe.read_now t.triggered_timers_r in
          let%map t' = (transition t t.state) >>| (with_new_state t) in
          Logger.debug t.logger !"Making transition from %{sexp:State.t} to %{sexp:State.t} at %{sexp:Peer.t} via timer\n%!" t.state t'.state t.ident;
          t'
      | false, None, Some msg ->
          let _ = Linear_pipe.read_now t.message_pipe in
          let checks = Message_label.Table.to_alist t.message_handlers in
          let matches = List.filter checks ~f:(fun (_, M (_, cond, _)) ->
            cond msg t.state
          ) in
          (match matches with
          | [] ->
              return (with_new_state t (t.state))
          | (label,M (_, _,transition))::[] ->
              let%map t' = (transition t msg t.state) >>| (with_new_state t) in
              Logger.debug t.logger !"Making transition from %{sexp:State.t} to %{sexp:State.t} at %{sexp:Peer.t} label: %{sexp:Message_label.label}\n%!" t.state t'.state t.ident label;
              t'
          | _::_::xs as l ->
            failwithf "Multiple conditions matched current state: %s"
              (List.map l ~f:(fun (label, _) -> label) |> List.sexp_of_t Message_label.sexp_of_label |> Sexp.to_string_hum) ())
      | false, None, None ->
          return (with_new_state t (t.state))

      let ident {ident} = ident
      let state {state} = state

      let send {transport} = Transport.send transport
      let send_exn t ~recipient msg =
        match%map send t ~recipient msg with
        | Ok () -> ()
        | Error e -> failwithf "Send failed %s" (Error.to_string_hum e) ()

      let send_multi t ~recipients msg =
        Deferred.List.all begin
          List.map recipients ~f:(fun r ->
            send t ~recipient:r msg
          )
        end

      let send_multi_exn t ~recipients msg =
        Deferred.List.all begin
          List.map recipients ~f:(fun r ->
            send_exn t ~recipient:r msg
          )
        end >>| (Fn.const ())
end

