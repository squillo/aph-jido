defmodule JidoAph.JidoPins.BareAgent do
  @moduledoc """
  Test-only agent with `default_plugins: false`, pinning the documented
  escape hatch that removes ALL framework default plugins
  (deps/jido/lib/jido/agent/default_plugins.ex,
  `apply_agent_overrides(_defaults, false)` returns `[]`).
  """

  use Jido.Agent,
    name: "pin_bare_agent",
    default_plugins: false,
    plugins: [JidoAph.JidoPins.ProbePlugin]
end
