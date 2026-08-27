defmodule JidoAph.JidoPins.DownstreamPlugin do
  @moduledoc """
  Test-only control plugin mounted AFTER the probe/patterned plugin in every
  pin agent. Its hooks report to the test process, so the pins can prove:

  - halt semantics: a `{:error, _}` from an earlier plugin's prepare_signal
    means this plugin's prepare_signal never runs
    (deps/jido/lib/jido/agent_server.ex, `run_plugin_prepare_signal_hooks/2`
    reduce_while halts on the first error);
  - empty `signal_patterns` receive every signal (control row for the
    wildcard-matching pins);
  - runtime-context deltas from earlier prepare_signal hooks arrive in later
    plugins' `context.runtime_context`
    (deps/jido/lib/jido/agent_server.ex, `invoke_plugin_prepare_action/7`).

  `signal.data.downstream_context` lets a test make THIS plugin contribute a
  context delta, to pin the duplicate-key fail-closed rule
  (`merge_plugin_runtime_context/4`).
  """

  use Jido.Plugin,
    name: "pin_downstream",
    state_key: :pin_downstream,
    actions: []

  alias JidoAph.JidoPins.Notify

  @impl Jido.Plugin
  def prepare_signal(signal, _context) do
    Notify.emit(signal, {:downstream_prepare_signal, signal.type})

    case signal.data do
      %{downstream_context: delta} when is_map(delta) -> {:ok, signal, delta}
      _ -> {:ok, signal, %{}}
    end
  end

  @impl Jido.Plugin
  def prepare_action(signal, action_arg, context) do
    Notify.emit(
      signal,
      {:downstream_prepare_action, signal.type, action_arg, context.runtime_context}
    )

    {:ok, %{}}
  end
end
