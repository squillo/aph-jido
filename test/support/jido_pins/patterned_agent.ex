defmodule JidoAph.JidoPins.PatternedAgent do
  @moduledoc """
  Test-only agent for the signal_patterns wildcard pins (PRD-001 T3).

  Mounts the patterned plugin FIRST and the empty-patterns downstream plugin
  SECOND, so every signal produces a downstream sighting (the control row)
  while patterned sightings depend purely on the server's pattern filter
  (deps/jido/lib/jido/agent_server.ex, `signal_matches_plugin?/2` /
  `signal_type_matches?/2`). Deliberately declares NO routes: the pins also
  prove prepare_signal hooks run BEFORE routing, so a guard sees signals
  that would otherwise die with a routing error.
  """

  use Jido.Agent,
    name: "pin_patterned_agent",
    plugins: [JidoAph.JidoPins.PatternedPlugin, JidoAph.JidoPins.DownstreamPlugin]
end
