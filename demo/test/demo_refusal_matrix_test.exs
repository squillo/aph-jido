# The `required: false` counterpart to `Demo.Agents.Gateway`, needed by row 6
# and by nothing else — so it lives here in the test file rather than in
# demo/lib, where it would read as a second shipped agent. Identical to the
# Gateway in every other respect (same mode policy, same scoping, same route),
# which is what makes row 6 a clean single-variable comparison against rows
# 1-5: only `:required` changed.
defmodule Demo.RefusalMatrixTest.PassThroughGateway do
  @moduledoc false

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

defmodule Demo.RefusalMatrixTest do
  # Why this file exists: it is PRD-001 §3 step 3 and T10 — the demo's
  # refusal matrix, six rows, driven through the REAL agent stack rather
  # than through `prepare_signal/2` in isolation. The library's
  # test/jido_aph/guard_test.exs already pins each gate branch as a unit;
  # what this file pins is the part a unit test cannot reach: that a guard
  # refusal actually STOPS the agent (no routed Action runs), that the
  # aph-ex message survives the framework's error wrapping byte-for-byte
  # out to the `Jido.AgentServer.call/2` caller, and that the refusal is
  # logged where an operator would see it.
  #
  # Fixture discipline (PRD-001 §10 gate 4): every negative below is derived
  # IN MEMORY at runtime from the sibling clone's committed goldens —
  # decode, tamper, re-encode — and nothing derived is ever committed. The
  # signed fixtures themselves are never text-edited. The envelope only ever
  # reaches the guard as JSON TEXT; the decode steps here exist solely to
  # build a variant or to read a fixture's own claim in an assertion, never
  # on the trust path.
  #
  # Non-vacuity of the "no Action ran" half of every refused row: each signal
  # carries `reply_to: self()` in its data, and `Demo.Actions.DeliverReply`
  # sends `{:deliver_reply_ran, params, context}` to that pid whenever it
  # runs — the rail proven live by test/demo_happy_path_test.exs. So a
  # `refute_receive` here means the Action did not run, not that the
  # observability rail was never wired.
  #
  # async: false — these tests drive the singleton `Demo.Jido` instance
  # started by the demo's supervision tree and capture VM-wide logs.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Demo.RefusalMatrixTest.PassThroughGateway
  alias Jido.AgentServer
  alias Jido.Signal

  # Every row drives a refusal, and the AgentServer logs its own [error] line
  # for a failed prepare_signal hook AFTER replying to the caller — outside
  # the `with_log/1` window each row uses for its assertions. This tag catches
  # those stragglers so they neither noise up the suite output nor drift into
  # the next test's capture window.
  @moduletag capture_log: true

  # Starts one gateway agent under the demo's Jido instance, with an id
  # unique per test so repeated runs in the same VM never collide in the
  # instance registry.
  defp start_gateway!(module) do
    {:ok, pid} =
      Demo.Jido.start_agent(module,
        id: "#{inspect(module)}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> Demo.Jido.stop_agent(pid) end)

    pid
  end

  # A `slack.reply.requested` signal carrying `envelope_json` as verbatim
  # JSON text on the T4 extension rail — the same helper the demo's own
  # presenting action uses (`JidoAph.attach_notarization/3`), never raw
  # `put_extension/3`.
  defp notarized_signal!(envelope_json) do
    signal = Signal.new!("slack.reply.requested", %{reply_to: self()})
    {:ok, signal} = JidoAph.attach_notarization(signal, envelope_json)
    signal
  end

  defp bare_signal, do: Signal.new!("slack.reply.requested", %{reply_to: self()})

  defp golden, do: Demo.Corpus.example!("principal_signed_envelope.json")
  defp mode_absent, do: Demo.Corpus.example!("slack_reply_envelope.json")

  # Drives the Gateway with a signal that must be refused, and proves both
  # halves of a matrix row at once: the caller gets the guard's reason
  # verbatim under the framework's `ExecutionError`, and the routed Action
  # never ran. Returns `{reason, log}` so each row can assert its own code.
  #
  # The `%Jido.Error.ExecutionError{}` shape is the framework's, pinned in
  # the library's test/jido_pins/prepare_signal_contract_test.exs: a
  # `prepare_signal/2` refusal halts before routing and surfaces with the
  # plugin's reason preserved under `details.reason`.
  defp refuse_and_prove_no_action_ran!(gateway, signal) do
    {result, log} = with_log(fn -> AgentServer.call(gateway, signal) end)

    assert {:error,
            %Jido.Error.ExecutionError{
              message: "Plugin prepare_signal failed",
              details: %{plugin: JidoAph.Guard, reason: reason}
            }} = result

    refute_receive {:deliver_reply_ran, _params, _context}, 100

    assert log =~ "aph_guard: refusing signal"

    {reason, log}
  end

  # ROW 1 — missing extension under required: true.
  #
  # Why this test exists: it is the a2a-extension.md §3/§5 `AgentExtension
  # required: true` mirror (PRD-001 §3 step 3, row 1) at integration depth.
  # a2a-extension.md §5 step 5: where the extension is absent and "the
  # recipient's deployment policy REQUIRES APH ... the endpoint REJECTS
  # messages from the agent and SHOULD log the rejection for audit" — both
  # halves, the rejection and the log line, asserted below.
  # It pins that an un-notarized signal never reaches the routed Action, and
  # that the refusal claims no APH_E code: nothing was parsed, so no protocol
  # rule was reached and none may be cited.
  test "row 1: a signal with no notarization extension is rejected and logged under required: true" do
    gateway = start_gateway!(Demo.Agents.Gateway)

    {reason, log} = refuse_and_prove_no_action_ran!(gateway, bare_signal())

    assert reason =~ "notarization extension missing"
    assert reason =~ "required: true"
    assert reason =~ "a2a-extension.md §5"
    refute reason =~ "APH_E"

    assert log =~ "notarization extension missing"
  end

  # ROW 2 — forged PrincipalSigned label.
  #
  # Why this test exists: spec §7.1.11 requires the attestation label and the
  # proof structure to agree in BOTH directions, and this is the forgery that
  # a mode gate alone would wave through — the library's guard_test pins that
  # admission-then-catch (`APH.require_attestation_mode/2` answers `:ok` on
  # this exact envelope). Here the same forgery is driven through the whole
  # agent: the variant is derived at runtime by writing a PrincipalSigned
  # label over the mode-absent golden's single-object proof, and the Gateway
  # must refuse it APH_E013 before `DeliverReply` runs. The second assertion
  # is the integration claim proper — the aph-ex message the guard passed
  # through untouched is still byte-identical after the framework wrapped it
  # in an ExecutionError, so callers can keep matching by code prefix.
  test "row 2: a forged PrincipalSigned label is refused APH_E013 and no Action runs" do
    forged =
      mode_absent()
      |> JSON.decode!()
      |> put_in(["credentialSubject", "policy", "attestationMode"], "PrincipalSigned")
      |> JSON.encode!()

    gateway = start_gateway!(Demo.Agents.Gateway)

    {reason, _log} = refuse_and_prove_no_action_ran!(gateway, notarized_signal!(forged))

    assert "APH_E013" <> _ = reason
    assert {:error, ^reason} = APH.verify_proof_structure(forged)
  end

  # ROW 3 — mode-absent envelope against a PrincipalSigned policy.
  #
  # Why this test exists: spec §8.3.1 step 1a with §7.1.7 — an ABSENT
  # `attestationMode` normatively means `NotaryAttested`, so a
  # `require_mode: "PrincipalSigned"` policy must refuse it up front with
  # APH_E012 and never silently downgrade to what the envelope happens to
  # offer. `slack_reply_envelope.json` is that envelope, untampered: its
  # policy carries no `attestationMode` at all, and its structure is sound
  # (asserted below — §7.1.11 alone says `{:ok, "NotaryAttested"}`), so the
  # refusal provably comes from the mode gate and nothing else.
  #
  # On the fixture's `decision: "AskEveryTime"`, asserted here so this
  # sentence is machine-checked rather than merely written: that field records
  # the human's STANDING CONFIGURATION — the policy mode they chose for this
  # channel — and is NEVER the verdict on this act. The spec is explicit
  # (§7.1.7, `PolicyDescriptor.decision`): it "Records the human's standing
  # configuration, NOT the verdict on this act", the verdict being carried by
  # the state the envelope was issued from (§9.1 admits no path to
  # `EnvelopeIssued` that bypasses `Approved`), so an `AskEveryTime` envelope
  # truthfully carries `AskEveryTime` after the human said yes.
  # "Implementations that read this field as a per-act decision have shipped
  # real defects; do not." Nothing in this repo reads it as one: the guard
  # never looks at `decision`, and this row's refusal is about
  # `attestationMode` alone.
  test "row 3: a mode-absent envelope against a PrincipalSigned policy is refused APH_E012" do
    envelope = mode_absent()

    # Read only to pin the fixture's own preconditions — never the trust path.
    policy = get_in(JSON.decode!(envelope), ["credentialSubject", "policy"])
    refute Map.has_key?(policy, "attestationMode")
    assert policy["decision"] == "AskEveryTime"

    # The structure itself is sound; only the mode policy is unsatisfied.
    assert {:ok, "NotaryAttested"} = APH.verify_proof_structure(envelope)

    gateway = start_gateway!(Demo.Agents.Gateway)

    {reason, _log} = refuse_and_prove_no_action_ran!(gateway, notarized_signal!(envelope))

    assert "APH_E012" <> _ = reason
    assert {:error, ^reason} = APH.require_attestation_mode(envelope, "PrincipalSigned")
  end

  # ROW 4 — unknown envelope field.
  #
  # Why this test exists: spec §8.3 step 1 parses STRICTLY, with unknown
  # fields denied, and a shape refusal must carry the parser's own message
  # and claim no APH_E code it did not earn — the taxonomy codes belong to
  # protocol rules, and a document that never parsed reached none of them.
  # The variant is derived at runtime by adding one field to the golden.
  test "row 4: an unknown envelope field is refused by strict parse, with no APH code" do
    tampered =
      golden()
      |> JSON.decode!()
      |> Map.put("jidoAphUnknownField", true)
      |> JSON.encode!()

    gateway = start_gateway!(Demo.Agents.Gateway)

    {reason, _log} = refuse_and_prove_no_action_ran!(gateway, notarized_signal!(tampered))

    assert reason =~ "jidoAphUnknownField"
    refute reason =~ "APH_E"
    assert {:error, ^reason} = APH.parse_envelope_json(tampered)
  end

  # ROW 5 — oversize envelope.
  #
  # Why this test exists: spec §7.1.7.1 puts a byte bound on the envelope
  # precisely because canonicalization happens on UNAUTHENTICATED input, so
  # the bound must be enforced before any parser sees the bytes. This proves
  # that ordering from the outside rather than by reading the guard: the
  # variant is the golden padded with trailing whitespace, which the strict
  # parser still ADMITS (asserted first), so the Gateway's refusal of those
  # same bytes can only have come from the pre-parse size gate. Like row 4,
  # the refusal cites no APH_E code — the bound is a bound, not a protocol
  # rule about the document's contents.
  test "row 5: an envelope over 64 KiB is refused before any parse" do
    padded = golden() <> String.duplicate(" ", 70_000)
    assert byte_size(padded) > JidoAph.Guard.max_envelope_bytes()

    # The parser would take these bytes; only the byte bound refuses them.
    assert {:ok, _} = APH.parse_envelope_json(padded)

    gateway = start_gateway!(Demo.Agents.Gateway)

    {reason, _log} = refuse_and_prove_no_action_ran!(gateway, notarized_signal!(padded))

    assert reason =~ "#{JidoAph.Guard.max_envelope_bytes()}-byte bound"
    assert reason =~ "refused before any parse"
    assert reason =~ "§7.1.7.1"
    refute reason =~ "APH_E"
  end

  # ROW 6 — bare signal under required: false.
  #
  # Why this test exists: it is the other half of the a2a-extension.md §5
  # mirror — step 6, the permissive deployment that "MAY display a 'Not
  # notarized' UI indicator and proceed to deliver the message under the
  # recipient's existing trust rules", i.e. deliver flagged unverified. Under
  # `required: false` an un-notarized signal is NOT refused: it passes
  # through and the Action runs, but tagged. This pins where the tag rides
  # (the runtime context the receiving guard authored, `context.aph`, never
  # the signal — a wire-borne tag would be sender-suppliable and is silently
  # stripped on any VM without the namespace registered) and, just as
  # importantly, pins what is NOT claimed: no verdict, no "notarization-
  # shaped", because nothing was examined. The log says only that the signal
  # arrived bare and was passed through unverified.
  test "row 6: a bare signal under required: false passes through tagged unverified" do
    gateway = start_gateway!(PassThroughGateway)

    {result, log} = with_log(fn -> AgentServer.call(gateway, bare_signal()) end)

    assert {:ok, %Jido.Agent{}} = result

    # The Action DID run here — this row is a pass-through, not a refusal.
    assert_receive {:deliver_reply_ran, _params, context}
    assert context.aph == %{notarization: :absent, tag: :unverified}

    assert log =~ "carries no notarization envelope"
    assert log =~ "passing through tagged unverified (required: false)"
    assert log =~ "would deliver (no channel adapter)"

    # Nothing was examined, so nothing may be claimed: no verdict wording,
    # and never the bare words the honesty contract forbids (§8) — note
    # "unverified" is not the bare word "verified".
    refute log =~ "notarization-shaped"
    refute log =~ ~r/\bverified\b/i
    refute log =~ ~r/\bsigned\b/i
  end
end
