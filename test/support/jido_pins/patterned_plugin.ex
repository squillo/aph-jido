defmodule JidoAph.JidoPins.PatternedPlugin do
  @moduledoc """
  Test-only plugin carrying the three `signal_patterns` shapes the wildcard
  pins exercise against deps/jido/lib/jido/agent_server.ex
  (`signal_type_matches?/2`):

  - `"slack.*"` — trailing `.*` (the shape JidoAph.Guard will ship with);
  - `"exact.match"` — no wildcard, equality only;
  - `"mid.*.tail"` — interior `*`, compiled to a single-segment regex.

  Its prepare_signal reports every signal it is invoked for, so a test can
  observe exactly which signal types the server filtered in or out.
  """

  use Jido.Plugin,
    name: "pin_patterned",
    state_key: :pin_patterned,
    actions: [],
    signal_patterns: ["slack.*", "exact.match", "mid.*.tail"]

  alias JidoAph.JidoPins.Notify

  @impl Jido.Plugin
  def prepare_signal(signal, _context) do
    Notify.emit(signal, {:patterned_saw, signal.type})
    {:ok, signal, %{}}
  end
end
