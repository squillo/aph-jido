defmodule JidoAph.JidoPins.Notify do
  @moduledoc """
  Test-only mailbox bridge for the jido pin suite (PRD-001 T3).

  Plugin hooks and routed actions run inside an AgentServer-spawned runner
  process, not the test process (deps/jido/lib/jido/agent_server.ex,
  `start_signal_call_task/3` spawns the runner that executes the whole hook
  chain and replies via the server). Every pin signal therefore carries the
  test pid in `signal.data.reply_to`, and hooks report what they saw by
  sending to that pid. Signals without a reply_to (framework-internal
  signals) are reported nowhere, which keeps the pins deterministic.
  """

  alias Jido.Signal

  @spec emit(Signal.t() | term(), term()) :: :ok
  def emit(%Signal{data: %{reply_to: pid}}, message) when is_pid(pid) do
    send(pid, message)
    :ok
  end

  def emit(_signal, _message), do: :ok
end
