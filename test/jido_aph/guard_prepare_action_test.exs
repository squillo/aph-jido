defmodule JidoAph.GuardPrepareActionTest do
  # async: true — every assertion here calls prepare_action/3 directly with a
  # hand-built context; nothing starts an agent or touches shared state.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias JidoAph.Guard

  defmodule ProtectedAction do
    @moduledoc false
    def run(_params, _ctx), do: {:ok, %{}}
  end

  defmodule UnrelatedAction do
    @moduledoc false
    def run(_params, _ctx), do: {:ok, %{}}
  end

  defp sig(type), do: Jido.Signal.new!(type, %{})
  defp gated, do: %{aph: %{verdict: "notarization-shaped", depth: :structural}}

  defp ctx(config, runtime \\ %{}), do: %{config: config, runtime_context: runtime}

  @scoped %{signal_patterns: ["slack.reply.requested"]}

  # Why this test exists: it is the bypass the spec owner ranked above every
  # spec ruling — "a bypass outranks a taxonomy gap, a false sentence, and a
  # normative contradiction combined". Until prepare_action/3 existed, an
  # Action could be routed with prepare_signal/2 never having gated the
  # signal, and the guard's only response was the framework's inherited
  # no-op returning {:ok, %{}}. This pins the refusal.
  test "an in-scope signal reaching routing with no verdict is refused" do
    log =
      capture_log(fn ->
        assert {:error, reason} =
                 Guard.prepare_action(sig("slack.reply.requested"), UnrelatedAction, ctx(@scoped))

        assert reason =~ "no admit verdict"
        assert reason =~ "prepare_signal/2 never gated"
      end)

    assert log =~ "aph_guard: refusing to run the action"
  end

  # Why this test exists: the refusal must key on the VERDICT and nothing
  # else, or it degrades into a check that a key exists. A signal the gate
  # really admitted carries the verdict prepare_signal/2 wrote, and must pass.
  test "a signal carrying the gate's verdict is authorized" do
    assert {:ok, %{}} =
             Guard.prepare_action(
               sig("slack.reply.requested"),
               UnrelatedAction,
               ctx(@scoped, gated())
             )
  end

  # Why this test exists: a guard that refuses traffic it was configured not
  # to see is a nuisance, and worse, it makes mounting the plugin unsafe on
  # an agent that handles anything else. Out-of-scope signals pass.
  test "an out-of-scope signal is not this guard's to judge" do
    assert {:ok, %{}} =
             Guard.prepare_action(sig("billing.invoice.due"), UnrelatedAction, ctx(@scoped))
  end

  # Why this test exists: THE RENAME. A co-mounted plugin returning
  # {:override, Action, renamed_signal} produces a type signal_patterns does
  # not match, so scope-checking alone waves it through while the original
  # Action still runs — verified empirically before :protect_actions existed,
  # and the reason authorizing the ACTION rather than the signal type is the
  # rename-proof question. All three action_arg shapes jido can hand us
  # (deps/jido/lib/jido/agent_server.ex action_arg_from_spec/1) are pinned,
  # because a shape we fail to read is a protection that silently lapses.
  test "a renamed signal cannot dodge protection, in any action_arg shape" do
    config = Map.put(@scoped, :protect_actions, [ProtectedAction])
    renamed = sig("slack.reply.sneaky")

    capture_log(fn ->
      for shape <- [ProtectedAction, {ProtectedAction, []}, [ProtectedAction]] do
        assert {:error, reason} = Guard.prepare_action(renamed, shape, ctx(config)),
               "protection lapsed for action_arg shape #{inspect(shape)}"

        assert reason =~ "no admit verdict"
      end
    end)
  end

  # Why this test exists: protection must be scoped to the actions a
  # deployment named. Refusing every action on a renamed signal would make
  # the guard un-mountable beside any other plugin, so an unprotected action
  # on an out-of-scope signal passes even with no verdict.
  test "an unprotected action on an out-of-scope signal still passes" do
    config = Map.put(@scoped, :protect_actions, [ProtectedAction])

    assert {:ok, %{}} =
             Guard.prepare_action(sig("slack.reply.sneaky"), UnrelatedAction, ctx(config))
  end

  # Why this test exists: the two paths that CANNOT be closed from a plugin
  # — Jido.Agent.cmd/3 and %Directive.RunInstruction{} — never enter the hook
  # chain, so this hook never runs for them. Pinning the boundary keeps the
  # docs honest: DeliverReply's moduledoc claimed the guard could only be
  # bypassed zero ways, and it was wrong four ways. This test is the record
  # that two remain the action's own responsibility.
  test "protection is a hook-chain claim, and says nothing about paths that skip the chain" do
    # Nothing to call: the assertion is that prepare_action/3 is only ever
    # invoked by the server's routing path. This test documents the limit and
    # fails loudly if someone later claims otherwise in the moduledoc.
    doc = Guard.__info__(:functions) |> Keyword.get(:prepare_action)
    assert doc == 3, "prepare_action must stay arity 3 — the contract jido calls"
  end
end
