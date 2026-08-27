defmodule JidoAph.JidoPins.PrepareSignalContractTest do
  use ExUnit.Case, async: true

  # Why this file exists: PRD-001 §7.1 builds JidoAph.Guard entirely on
  # jido's prepare_signal/2 hook, whose refusal/halt contract is unpinned in
  # docs. Every test here pins one branch of the REAL contract in
  # deps/jido/lib/jido/agent_server.ex (invoke_plugin_prepare_signal/6,
  # run_plugin_prepare_signal_hooks/2, merge_plugin_runtime_context/4) —
  # source beats docs. A red test here is a design-input change for T7, not
  # something to work around.

  alias Jido.AgentServer
  alias Jido.Signal
  alias JidoAph.JidoPins.{DownstreamPlugin, ProbeAgent, ProbePlugin}

  defp start_server! do
    start_supervised!(
      {AgentServer,
       [
         agent: ProbeAgent,
         id: "pin-probe-#{System.unique_integer([:positive])}",
         register_global: false
       ]}
    )
  end

  defp signal!(type, extra_data) do
    Signal.new!(type, Map.merge(%{reply_to: self()}, extra_data))
  end

  # Why: the guard's happy path (PRD-001 §3 step 2) rides this exact shape —
  # {:ok, signal, context_delta} continues through routing to the action.
  # Pins deps/jido/lib/jido/agent_server.ex compute_signal_call_result/2:
  # prepare_signal hooks run, then route_to_actions, then the action, and
  # the synchronous call returns {:ok, agent}. Also pins default-plugin
  # non-interference on the hook chain: Thread/Identity/Memory sit FIRST in
  # the chain with identity prepare_signal defaults, and the signal still
  # reaches our plugins and action unchanged.
  test "admitted signal flows prepare_signal -> routing -> action, call returns {:ok, agent}" do
    pid = start_server!()

    assert {:ok, %Jido.Agent{}} = AgentServer.call(pid, signal!("pin.ok", %{}))
    assert_receive {:probe_prepare_signal, "pin.ok"}
    assert_receive {:downstream_prepare_signal, "pin.ok"}
    assert_receive {:downstream_prepare_action, "pin.ok", _action_arg, %{}}
    assert_receive {:action_ran, params, _context}
    assert params.reply_to == self()
  end

  # Why: this is THE guard refusal contract T7 builds on. Pins
  # deps/jido/lib/jido/agent_server.ex invoke_plugin_prepare_signal/6: a
  # plugin's {:error, reason} is wrapped in
  # Jido.Error.execution_error("Plugin prepare_signal failed", %{plugin:
  # module, reason: reason}) — the guard's refusal term survives verbatim
  # under details.reason — and run_plugin_prepare_signal_hooks/2 halts, so
  # later plugins' prepare_signal and the routed action NEVER run.
  test "prepare_signal {:error, reason} halts the chain before routing and the action" do
    pid = start_server!()

    assert {:error, %Jido.Error.ExecutionError{message: msg, details: details}} =
             AgentServer.call(pid, signal!("pin.ok", %{probe: :refuse, reason: :aph_refused}))

    assert msg == "Plugin prepare_signal failed"
    assert details.plugin == ProbePlugin
    assert details.reason == :aph_refused

    assert_receive {:probe_prepare_signal, "pin.ok"}
    refute_receive {:downstream_prepare_signal, _}, 50
    refute_receive {:action_ran, _, _}, 10

    # The refusal must not take the server down (the guard refuses per
    # signal; the agent keeps serving) — a follow-up admit succeeds.
    assert {:ok, _} = AgentServer.call(pid, signal!("pin.ok", %{}))
    assert_receive {:action_ran, _, _}
  end

  # Why: the guard must return refusals, never raise — but if it ever does
  # raise, the failure mode matters. Pins the rescue clause in
  # deps/jido/lib/jido/agent_server.ex invoke_plugin_prepare_signal/6: a
  # raise inside prepare_signal is converted to an ExecutionError
  # ("Plugin prepare_signal crashed", details.exception carries the message)
  # and the AgentServer itself survives.
  test "a raise inside prepare_signal fails closed as an error, server survives" do
    pid = start_server!()

    assert {:error, %Jido.Error.ExecutionError{message: msg, details: details}} =
             AgentServer.call(pid, signal!("pin.ok", %{probe: :raise}))

    assert msg == "Plugin prepare_signal crashed"
    assert details.exception =~ "probe boom"

    assert Process.alive?(pid)
    assert {:ok, _} = AgentServer.call(pid, signal!("pin.ok", %{}))
  end

  # Why: PRD-001 assumed the callback returns "{:ok, signal} | {:error, _}"
  # style in early drafts; the REAL contract is a strict 3-tuple
  # {:ok, %Signal{}, context_delta_map}. Pins the `other ->` clause of
  # deps/jido/lib/jido/agent_server.ex invoke_plugin_prepare_signal/6: any
  # other shape (here a bare {:ok, signal} 2-tuple) is refused as
  # "Plugin prepare_signal returned invalid result" — malformed guards fail
  # closed, they do not pass signals through.
  test "a 2-tuple {:ok, signal} return is an invalid result, refused" do
    pid = start_server!()

    assert {:error, %Jido.Error.ExecutionError{message: msg, details: details}} =
             AgentServer.call(pid, signal!("pin.ok", %{probe: :bad_shape}))

    assert msg == "Plugin prepare_signal returned invalid result"
    assert details.plugin == ProbePlugin
  end

  # Why: the guard's pass-through-tagged-unverified design (PRD-001 §3 row 6)
  # needs a channel to downstream phases; the runtime-context delta is that
  # channel, and its reserved keys are enforced. Pins
  # deps/jido/lib/jido/agent_server.ex @reserved_runtime_context_keys +
  # merge_plugin_runtime_context/4: a delta containing :signal fails closed
  # with the exact message and offending keys.
  test "reserved runtime-context keys in the delta fail closed" do
    pid = start_server!()

    assert {:error, %Jido.Error.ExecutionError{message: msg, details: details}} =
             AgentServer.call(pid, signal!("pin.ok", %{probe: :reserved_context}))

    assert msg == "Plugin prepare_signal returned reserved runtime context keys"
    assert details.plugin == ProbePlugin
    assert details.keys == [:signal]
  end

  # Why: two plugins writing the same context key must not silently
  # overwrite each other — jido docs say "duplicate context keys fail
  # closed" (deps/jido/lib/jido/plugin.ex prepare_signal @doc) and this pins
  # the mechanism in deps/jido/lib/jido/agent_server.ex
  # merge_plugin_runtime_context/4: the SECOND writer is refused with
  # "Plugin prepare_signal returned duplicate runtime context keys".
  test "duplicate runtime-context keys across plugins fail closed" do
    pid = start_server!()

    signal =
      signal!("pin.ok", %{
        probe: :context,
        key: :aph_tag,
        value: :unverified,
        downstream_context: %{aph_tag: :duplicate}
      })

    assert {:error, %Jido.Error.ExecutionError{message: msg, details: details}} =
             AgentServer.call(pid, signal)

    assert msg == "Plugin prepare_signal returned duplicate runtime context keys"
    assert details.plugin == DownstreamPlugin
    assert details.keys == [:aph_tag]
  end

  # Why: this is the mechanism the guard will use to hand its verdict to the
  # action layer. Pins deps/jido/lib/jido/agent_server.ex
  # compute_signal_call_result/2 + invoke_plugin_prepare_action/7 + the
  # cmd/3 context plumbing in deps/jido/lib/jido/agent.ex
  # (__jido_action_context__): a prepare_signal context delta reaches later
  # plugins' context.runtime_context AND the routed action's run/2 context.
  test "runtime-context delta from prepare_signal reaches prepare_action and the action" do
    pid = start_server!()

    assert {:ok, _} =
             AgentServer.call(
               pid,
               signal!("pin.ok", %{probe: :context, key: :aph_tag, value: :unverified})
             )

    assert_receive {:downstream_prepare_action, "pin.ok", _arg, %{aph_tag: :unverified}}
    assert_receive {:action_ran, _params, context}
    assert context.aph_tag == :unverified
  end

  # Why: prepare_signal is documented as the canonicalize/rewrite hook, and
  # the guard design must know whether a rewrite feeds ROUTING or only later
  # hooks. Pins deps/jido/lib/jido/agent_server.ex
  # run_plugin_prepare_signal_hooks/2 + compute_signal_call_result/2: the
  # rewritten signal is what later plugins see AND what the router routes —
  # "pin.ok" is rewritten to "pin.rewritten" and the "pin.rewritten" route
  # fires.
  test "a rewritten signal from prepare_signal feeds later hooks and routing" do
    pid = start_server!()

    assert {:ok, _} =
             AgentServer.call(pid, signal!("pin.ok", %{probe: :rewrite, to: "pin.rewritten"}))

    assert_receive {:probe_prepare_signal, "pin.ok"}
    assert_receive {:downstream_prepare_signal, "pin.rewritten"}
    assert_receive {:action_ran, params, _context}
    assert params.probe == :rewrite
  end
end
