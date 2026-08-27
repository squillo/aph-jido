defmodule JidoAph.JidoPins.SignalPatternsTest do
  use ExUnit.Case, async: true

  # Why this file exists: JidoAph.Guard takes a `signal_patterns` config
  # (PRD-001 §7.1) and jido's wildcard semantics for the plugin hook filter
  # are undocumented. These tests pin the REAL matcher in
  # deps/jido/lib/jido/agent_server.ex (signal_matches_plugin?/2,
  # signal_type_matches?/2) by observing which signals reach a patterned
  # plugin's prepare_signal on a live AgentServer. The one that matters
  # most: a trailing ".*" is a MULTI-SEGMENT prefix match, while an interior
  # "*" is single-segment — a guard patterned "slack.*" WILL see
  # "slack.reply.requested".

  alias Jido.AgentServer
  alias Jido.Signal

  defp start_server! do
    start_supervised!(
      {AgentServer,
       [
         agent: JidoAph.JidoPins.PatternedAgent,
         id: "pin-patterned-#{System.unique_integer([:positive])}",
         register_global: false
       ]}
    )
  end

  # Sends one signal and returns whether the patterned plugin saw it. The
  # empty-patterns downstream plugin is the synchronization point: it sees
  # EVERY signal, and it runs AFTER the patterned plugin in the same runner
  # process, so once its message arrives the patterned sighting (if any) is
  # already in our mailbox.
  defp patterned_saw?(pid, type) do
    signal = Signal.new!(type, %{reply_to: self()})

    # PatternedAgent has no routes: the call comes back as a routing error,
    # which is itself part of the pin (hooks run BEFORE routing).
    assert {:error, %Jido.Error.RoutingError{}} = AgentServer.call(pid, signal)
    assert_receive {:downstream_prepare_signal, ^type}

    receive do
      {:patterned_saw, ^type} -> true
    after
      0 -> false
    end
  end

  # Why: pins two facts at once from deps/jido/lib/jido/agent_server.ex —
  # (1) do_process_signal/compute_signal_call_result run the prepare_signal
  # hook phase BEFORE route_to_actions, so a guard sees signals that have no
  # route at all ("No route for signal" comes back to the caller as a
  # Jido.Error.RoutingError only AFTER the hooks ran); (2) a plugin with
  # empty signal_patterns receives every inbound signal
  # (signal_matches_plugin?/2 first clause returns true for []).
  test "hooks run before routing, and empty patterns receive everything" do
    pid = start_server!()

    signal = Signal.new!("unrelated.type", %{reply_to: self()})

    assert {:error, %Jido.Error.RoutingError{message: "No route for signal"}} =
             AgentServer.call(pid, signal)

    assert_receive {:downstream_prepare_signal, "unrelated.type"}
    refute_receive {:patterned_saw, _}, 10
  end

  # Why: "slack.*" is the exact pattern shape the guard demo ships with, and
  # the trailing-".*" branch of signal_type_matches?/2
  # (deps/jido/lib/jido/agent_server.ex) is a PREFIX match on "slack." —
  # multi-segment, so the three-segment "slack.reply.requested" matches too,
  # while the bare type "slack" and a lookalike prefix "slackish.reply" do
  # not. Getting this wrong would make the guard silently skip (or
  # double-cover) real traffic.
  test ~s(trailing ".*" is a multi-segment prefix match, excluding the bare prefix) do
    pid = start_server!()

    assert patterned_saw?(pid, "slack.reply")
    assert patterned_saw?(pid, "slack.reply.requested")
    refute patterned_saw?(pid, "slack")
    refute patterned_saw?(pid, "slackish.reply")
  end

  # Why: pins the other two branches of signal_type_matches?/2
  # (deps/jido/lib/jido/agent_server.ex): a wildcard-free pattern matches by
  # string equality ONLY (no implicit prefixing — "exact.match.extra" does
  # not match "exact.match"), and an interior "*" compiles to the
  # single-segment regex "[^.]*" ("mid.a.b.tail" does NOT match
  # "mid.*.tail").
  test ~s(exact patterns are equality-only; interior "*" is single-segment) do
    pid = start_server!()

    assert patterned_saw?(pid, "exact.match")
    refute patterned_saw?(pid, "exact.match.extra")
    assert patterned_saw?(pid, "mid.reply.tail")
    refute patterned_saw?(pid, "mid.a.b.tail")
  end
end
