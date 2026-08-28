defmodule Demo.Actions.DeliverReply do
  @moduledoc """
  Gateway's routed action — the demo's stand-in for a Slack channel
  adapter that deliberately does not exist (PRD-001 §5: no real Slack
  delivery; `channel.kind` names the end-delivery medium, spec §1.1.1).

  ## What gating this action actually guarantees — corrected

  This moduledoc used to say the action "can only run AFTER
  `JidoAph.Guard` admitted the signal". **That was false, in four ways**,
  and it is corrected here rather than quietly deleted because the claim
  is exactly the kind a reader would build on.

  What IS true: `prepare_signal/2` runs before routing (pinned in the
  library's test/jido_pins/prepare_signal_contract_test.exs), so a signal
  that reaches this action *through the routing path* was gated, and the
  guard's admission facts arrive as `context.aph` — the runtime-context
  delta merged into `run/2`'s context.

  What is NOT true, and the four paths that broke the old sentence:

    1. a co-mounted plugin returning `{:override, Action, renamed_signal}`,
       where the rename dodges the guard's `:signal_patterns`;
    2. a route pattern wider than the guard's — `"slack.reply.*"` against
       `["slack.reply.requested"]`;
    3. `Jido.Agent.cmd/3`, which never enters the hook chain;
    4. `%Directive.RunInstruction{}`, likewise.

  The guard now closes (1) and (2) in `prepare_action/3` — configure
  `:protect_actions` with this module and a rename cannot route it
  un-gated. **(3) and (4) cannot be closed from a plugin at all**, because
  neither ever invokes a hook. For those, an action that must not run
  un-gated has to check for itself, which is what `gated!/1` below is
  for.

  So the honest sentence is: gated on the routing path, and self-defending
  off it.

  Honesty: this action logs `would deliver (no channel adapter)` and
  stops. It never claims delivery happened, and it repeats no claim the
  guard did not earn — anything it surfaces from `context.aph` is the
  guard's own wording, verbatim.
  """

  use Jido.Action,
    name: "deliver_reply",
    description: "Logs the would-deliver beat; no channel adapter exists"

  require Logger

  @impl Jido.Action
  def run(params, context) do
    # The self-defense the moduledoc promises. `Jido.Agent.cmd/3` and
    # `%Directive.RunInstruction{}` never enter the hook chain, so NO plugin
    # can gate them — an action that must not run un-gated has to look for
    # the verdict itself. Fail closed: no verdict means the gate did not run,
    # whatever route got us here.
    with :ok <- gated!(context) do
      deliver(params, context)
    end
  end

  @doc """
  Refuses execution when the runtime context shows the guard never ran.

  This exists because two of the four paths that can reach this action skip
  the hook chain entirely (see the moduledoc). It is the action's own
  check, deliberately duplicated from the guard's `prepare_action/3` rather
  than delegated to it, because the whole point is that on those two paths
  the guard is never invoked to delegate to.

  ## What it asks, and what it deliberately does not

  It asks **did the gate run**, not **did the gate admit**. Those differ,
  and conflating them broke the demo the first time this was written: under
  `required: false` the guard passes an un-notarized signal through TAGGED
  (`%{aph: %{notarization: :absent, tag: :unverified}}`) — the
  a2a-extension.md §5 permissive path, where a deployment chooses to
  deliver flagged rather than refuse. That context carries no `:verdict`,
  and refusing it would have overridden a deployment's own configured
  policy from inside an action, which is not this function's business.

  So the rule is narrow: an `:aph` key authored by the guard means the gate
  ran and reached SOME decision, and the action proceeds. Its complete
  absence means no hook ever fired, and the action refuses.
  """
  @spec gated!(map()) :: :ok | {:error, String.t()}
  def gated!(context) do
    case context[:aph] do
      %{} ->
        :ok

      _ ->
        Logger.warning(
          "deliver_reply: refusing to run — no JidoAph.Guard context at all, so this action " <>
            "was reached by a path the guard never gated (Jido.Agent.cmd/3 or a " <>
            "RunInstruction directive, neither of which invokes a plugin hook)"
        )

        {:error, "deliver_reply refused: no APH context — the gate never ran on this path"}
    end
  end

  defp deliver(params, context) do
    Logger.info("deliver_reply: would deliver (no channel adapter)")

    # Observability rail, mirroring the library's pin-suite NotifyAction:
    # report execution (params + context) so integration tests can prove
    # this action DID run and that the guard's verdict reached it. Nothing
    # on the trust path reads :reply_to.
    if is_pid(params[:reply_to]) do
      send(params[:reply_to], {:deliver_reply_ran, params, context})
    end

    {:ok, %{delivery: :none}}
  end
end
