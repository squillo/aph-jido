defmodule Demo.Agents.Gateway do
  @moduledoc """
  The consumer-side agent (PRD-001 §3): refuses to act unless the signal
  carries a notarization-shaped, PrincipalSigned-labeled envelope.

  Mounts `JidoAph.Guard` with the demo policy the library's own config
  tests pre-validate (test/jido_aph/guard_config_test.exs — "the demo
  Gateway's mount config validates and merges defaults"):

  - `required: true` — a signal with no envelope is refused and logged,
    the a2a-extension.md §5 `AgentExtension required: true` mirror;
  - `require_mode: "PrincipalSigned"` — a mode-absent envelope
    (normatively NotaryAttested, spec §7.1.7) is refused APH_E012, no
    silent downgrade;
  - `signal_patterns: ["slack.reply.requested"]` — the gate is scoped to
    the one signal type this agent routes.

  The guard's `prepare_signal/2` gate runs BEFORE routing (pinned in the
  library's test/jido_pins/prepare_signal_contract_test.exs), so
  `Demo.Actions.DeliverReply` never sees an unadmitted signal. What an
  admission means — and what it does NOT — is the guard's claim, not this
  agent's: notarization-shaped, mode policy satisfied. Zero signatures
  checked.
  """

  use Jido.Agent,
    name: "gateway",
    plugins: [
      {JidoAph.Guard,
       %{
         required: true,
         require_mode: "PrincipalSigned",
         signal_patterns: ["slack.reply.requested"]
       }}
    ],
    signal_routes: [
      {"slack.reply.requested", Demo.Actions.DeliverReply}
    ]
end
