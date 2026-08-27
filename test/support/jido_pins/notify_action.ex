defmodule JidoAph.JidoPins.NotifyAction do
  @moduledoc """
  Test-only routed action for the jido pin suite (PRD-001 T3).

  Reports its own execution (params + context) to the test process, so pin
  tests can prove an action DID or DID NOT run after the plugin hook phases.
  Route targets that are bare modules receive `signal.data` as params
  (deps/jido/lib/jido/agent_server.ex, `target_to_action/2`), and an empty
  action schema preserves unknown params instead of rejecting them
  (deps/jido_action/lib/jido_action/runtime.ex, `split_known_and_unknown/2`),
  which is how `reply_to` reaches this action.
  """

  use Jido.Action,
    name: "pin_notify",
    description: "Reports execution to the pin-test process"

  @impl Jido.Action
  def run(params, context) do
    if is_pid(params[:reply_to]) do
      send(params[:reply_to], {:action_ran, params, context})
    end

    {:ok, %{}}
  end
end
