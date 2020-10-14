open Frontier_base

type create_args = {db: Database.t; logger: Logger.t}

type input = Diff.Lite.E.t list

val oc : Core.Out_channel.t

include
  Otp_lib.Worker_supervisor.S
  with type create_args := create_args
   and type input := input
   and type output := unit
