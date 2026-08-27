defmodule Demo.Actions.DeliverReply do
  @moduledoc """
  Gateway's routed action — the demo's stand-in for a Slack channel
  adapter that deliberately does not exist (PRD-001 §5: no real Slack
  delivery; `channel.kind` names the end-delivery medium, spec §1.1.1).

  It can only run AFTER `JidoAph.Guard` admitted the signal —
  prepare_signal hooks run before routing (pinned in the library's
  test/jido_pins/prepare_signal_contract_test.exs) — and the guard's
  admission facts reach it as `context.aph`, the runtime-context delta
  merged into the routed action's `run/2` context (same pin file, "runtime
  -context delta from prepare_signal reaches prepare_action and the
  action").

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
