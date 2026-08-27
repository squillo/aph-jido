defmodule JidoAph.JidoPins.ProbeAgent do
  @moduledoc """
  Test-only agent for the prepare_signal contract pins (PRD-001 T3).

  Default plugins are deliberately LEFT ENABLED: every pin that passes a
  signal through this agent also proves the framework defaults
  (Jido.Thread.Plugin / Jido.Agent.Identity.Plugin / Jido.Memory.Plugin,
  deps/jido/lib/jido/agent/default_plugins.ex) do not interfere with a
  mounted plugin's hooks or refusals — they are declared FIRST in the chain
  (deps/jido/lib/jido/agent.ex, `@all_plugin_decls @default_plugin_list ++
  plugins`) and their prepare_signal is the identity default
  (deps/jido/lib/jido/plugin.ex, `generate_default_callbacks/0`).

  Routes exist for "pin.ok" and "pin.rewritten" so admitted signals reach a
  real action; every other type exercises the no-route path.
  """

  use Jido.Agent,
    name: "pin_probe_agent",
    plugins: [JidoAph.JidoPins.ProbePlugin, JidoAph.JidoPins.DownstreamPlugin],
    signal_routes: [
      {"pin.ok", JidoAph.JidoPins.NotifyAction},
      {"pin.rewritten", JidoAph.JidoPins.NotifyAction}
    ]
end
