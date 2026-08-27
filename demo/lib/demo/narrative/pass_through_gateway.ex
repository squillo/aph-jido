defmodule Demo.Narrative.PassThroughGateway do
  @moduledoc """
  The `required: false` counterpart to `Demo.Agents.Gateway`, needed by the
  narrative's last refusal-matrix row and by nothing else.

  Identical to the Gateway in every other respect — same mode policy, same
  scoping, same route — so row 6 is a clean single-variable comparison
  against rows 1-5: only `:required` changed.

  ## Why it lives here rather than in `demo/lib/demo/agents/`

  Plugin config is fixed when the agent module compiles: `use Jido.Agent`
  evaluates `@plugin_instances Jido.Agent.__normalize_plugin_instances__(...)`
  at module-attribute time (deps/jido/lib/jido/agent.ex), and
  `Jido.AgentServer` reads its plugin specs back from the agent MODULE at
  runtime (`get_plugin_specs_and_instances/1` in
  deps/jido/lib/jido/agent_server.ex). There is no start-time override, so
  a second `required: false` mount has to be a second module.

  It sits under `Demo.Narrative` because it is narration scaffolding, not
  part of the demonstration's cast: `demo/lib/demo/agents/` holds the two
  agents the story is about, and a third one there would read as a third
  participant. `Demo.RefusalMatrixTest` makes the same call for the same
  reason and keeps its own copy inside the test file.

  Honesty: this gateway claims less than the Gateway does, not more. Under
  `required: false` an un-notarized signal is delivered TAGGED UNVERIFIED
  (`context.aph == %{notarization: :absent, tag: :unverified}`) — the
  a2a-extension.md §5 permissive-policy path, where an endpoint "MAY display
  a 'Not notarized' UI indicator and proceed to deliver the message under
  the recipient's existing trust rules". Nothing was examined, so no verdict
  is issued.
  """

  use Jido.Agent,
    name: "pass_through_gateway",
    plugins: [
      {JidoAph.Guard,
       %{
         required: false,
         require_mode: "PrincipalSigned",
         signal_patterns: ["slack.reply.requested"]
       }}
    ],
    signal_routes: [
      {"slack.reply.requested", Demo.Actions.DeliverReply}
    ]
end
