defmodule Demo.Actions.RequestSlackReply do
  @moduledoc """
  Scribe's presenting action (PRD-001 §3 step 2).

  Loads the golden envelope and its git-tracked 427-byte body from the
  sibling aph clone, attaches both to a `slack.reply.requested` signal
  through `JidoAph.attach_notarization/3` — the T4 helper rail, never raw
  `Jido.Signal.put_extension/3` (the helper self-heals the warm-`_build`
  extension-registry gotcha before it writes) — and hands the signal to
  the Gateway with `Jido.AgentServer.call/2`.

  `call/2` is the delivery mechanism the pin suite proved
  (test/jido_pins/prepare_signal_contract_test.exs: hooks run, then
  routing, then the action, and the caller gets `{:ok, agent}`). The
  parent-directed alternative is unavailable by construction:
  `Jido.Agent.Directive.emit_to_parent/3` returns `nil` for any agent
  without a `%Jido.AgentServer.ParentRef{}` in `state.__parent__`
  (deps/jido/lib/jido/agent/directive.ex, final clause), and these agents
  are standalone siblings under `Demo.Jido`.

  The envelope travels as verbatim JSON TEXT and the authorized body bytes
  travel verbatim as base64 (`body_b64`), exactly as read from disk —
  nothing is decoded or re-serialized on this path.

  Honesty: the envelope is a PRE-MINTED committed golden; attaching it
  asserts nothing about this run. Nothing here was humanly authorized, and
  this action claims nothing beyond "the bytes were presented".

  ## Params

  Route targets that are bare modules receive `signal.data` as params
  (deps/jido/lib/jido/agent_server.ex, `target_to_action/2`), so these are
  the keys the `scribe.reply.requested` signal must carry:

  - `:gateway` (required) — anything `Jido.AgentServer.call/2` accepts as
    a server reference; the demo passes the Gateway's pid.
  - `:reply_to` (optional) — pid forwarded on the slack signal's data so
    `Demo.Actions.DeliverReply` can report its own execution. An
    observability rail, mirroring the library's pin-suite
    `JidoAph.JidoPins.NotifyAction`; nothing on the trust path reads it.
  """

  use Jido.Action,
    name: "request_slack_reply",
    description: "Presents the golden APH envelope to the Gateway on slack.reply.requested"

  @envelope "principal_signed_envelope.json"
  @body "principal_signed_body.txt"

  @impl Jido.Action
  def run(params, _context) do
    gateway = Map.fetch!(params, :gateway)

    envelope_json = Demo.Corpus.example!(@envelope)
    body_bytes = Demo.Corpus.example!(@body)

    data =
      case params[:reply_to] do
        pid when is_pid(pid) -> %{reply_to: pid}
        _ -> %{}
      end

    signal = Jido.Signal.new!("slack.reply.requested", data)

    {:ok, signal} =
      JidoAph.attach_notarization(signal, envelope_json, body_b64: Base.encode64(body_bytes))

    # Synchronous delivery: the Gateway's guard gates in prepare_signal
    # before its routed action runs, so an admit surfaces here as
    # {:ok, agent} and a refusal as {:error, %Jido.Error.ExecutionError{}}
    # carrying the guard's reason verbatim under details.reason. The
    # refusal is returned unwrapped so the caller reads the guard's own
    # words, not this action's paraphrase.
    case Jido.AgentServer.call(gateway, signal) do
      {:ok, %Jido.Agent{}} -> {:ok, %{gateway: :admitted, body_bytes: byte_size(body_bytes)}}
      {:error, reason} -> {:error, reason}
    end
  end
end
