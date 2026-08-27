defmodule Demo.Agents.Scribe do
  @moduledoc """
  The presenting agent (PRD-001 §3): acts on behalf of a human by
  presenting the golden PRE-MINTED envelope to the Gateway.

  Routes `scribe.reply.requested` to `Demo.Actions.RequestSlackReply`,
  which attaches the envelope via `JidoAph.attach_notarization/3` and
  delivers to the Gateway with `Jido.AgentServer.call/2`.

  Scribe mounts no guard: it presents envelopes, it does not gate them.
  Presenting asserts nothing — the envelope is a committed golden fixture
  minted elsewhere, and nothing about this demo's run was humanly
  authorized.
  """

  use Jido.Agent,
    name: "scribe",
    signal_routes: [
      {"scribe.reply.requested", Demo.Actions.RequestSlackReply}
    ]
end
