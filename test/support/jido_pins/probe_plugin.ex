defmodule JidoAph.JidoPins.ProbePlugin do
  @moduledoc """
  Test-only plugin whose `prepare_signal/2` behavior is chosen per-signal by
  `signal.data.probe`, so one mounted plugin can exercise every branch of the
  AgentServer prepare_signal contract (deps/jido/lib/jido/agent_server.ex,
  `invoke_plugin_prepare_signal/6` and `merge_plugin_runtime_context/4`).

  Declared with no `signal_patterns`, which the server treats as
  match-everything for the hook phases (deps/jido/lib/jido/agent_server.ex,
  `signal_matches_plugin?/2` — empty patterns return true). The Zoi state
  schema exists so the default-plugin pin can prove this plugin's state slice
  is seeded under `:pin_probe` (deps/jido/lib/jido/agent.ex,
  `__build_initial_state__/1`).
  """

  use Jido.Plugin,
    name: "pin_probe",
    state_key: :pin_probe,
    actions: [],
    schema: Zoi.object(%{seen: Zoi.integer() |> Zoi.default(0)})

  alias JidoAph.JidoPins.Notify

  @impl Jido.Plugin
  def prepare_signal(signal, _context) do
    Notify.emit(signal, {:probe_prepare_signal, signal.type})

    case signal.data do
      %{probe: :refuse, reason: reason} -> {:error, reason}
      %{probe: :raise} -> raise "probe boom"
      %{probe: :bad_shape} -> {:ok, signal}
      %{probe: :reserved_context} -> {:ok, signal, %{signal: :hijacked}}
      %{probe: :context, key: key, value: value} -> {:ok, signal, %{key => value}}
      %{probe: :rewrite, to: new_type} -> {:ok, %{signal | type: new_type}, %{}}
      _ -> {:ok, signal, %{}}
    end
  end
end
