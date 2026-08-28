defmodule Demo.HappyPathTest do
  # async: false — every test here drives the singleton `Demo.Jido` instance
  # started by the demo's own supervision tree and captures VM-wide logs.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.AgentServer
  alias Jido.Signal

  # The guard's fixed verdict wording (PRD-001 §3 step 2 / §8), spelled here
  # so a drift in JidoAph.Guard.admit/3 fails THIS test loudly rather than
  # quietly changing what the demo claims.
  @verdict "notarization-shaped, mode policy satisfied (PrincipalSigned)"

  # Starts one Scribe and one Gateway under the demo's Jido instance
  # (deps/jido/lib/jido.ex start_agent/3 -> DynamicSupervisor.start_child).
  # Ids are unique per test so a re-run in the same VM never collides in the
  # instance registry.
  defp start_agents! do
    suffix = System.unique_integer([:positive])

    {:ok, gateway} = Demo.Jido.start_agent(Demo.Agents.Gateway, id: "gateway-#{suffix}")
    {:ok, scribe} = Demo.Jido.start_agent(Demo.Agents.Scribe, id: "scribe-#{suffix}")

    on_exit(fn ->
      Demo.Jido.stop_agent(gateway)
      Demo.Jido.stop_agent(scribe)
    end)

    {scribe, gateway}
  end

  # The whole happy-path leg, captured: start both agents, then ask Scribe to
  # present. Returns the captured log; the DeliverReply report lands in the
  # calling test's mailbox.
  defp run_happy_path! do
    capture_log(fn ->
      {scribe, gateway} = start_agents!()

      assert {:ok, %Jido.Agent{}} =
               AgentServer.call(
                 scribe,
                 Signal.new!("scribe.reply.requested", %{gateway: gateway, reply_to: self()})
               )
    end)
  end

  # Why this test exists: it is PRD-001 T9's DONE condition — the demo's two
  # agents must actually exchange the golden envelope end to end. It pins
  # that the Gateway ADMITS it with the fixed verdict wording, that the
  # admission facts reach the routed action as `context.aph`, and that
  # DeliverReply really ran (the guard gates in prepare_signal, before
  # routing, so a refusal would leave this message unsent). Together these
  # prove the T4 attach helper, the T7/T8 guard, and jido's hook->route->act
  # chain compose in a real app, not just in unit tests.
  test "the golden envelope is admitted with the fixed verdict and DeliverReply runs" do
    log = run_happy_path!()

    assert_receive {:deliver_reply_ran, params, context}
    assert params.reply_to == self()

    # The guard's own words, handed to the action verbatim.
    assert context.aph.verdict == @verdict
    assert context.aph.require_mode == "PrincipalSigned"
    assert context.aph.structure_mode == "PrincipalSigned"
    # What the gate RAN, never what a config declared.
    assert context.aph.depth == :structural

    assert log =~ @verdict
    assert log =~ "would deliver (no channel adapter)"
  end

  # Why this test exists: the library pins the `:claims` map by calling
  # prepare_signal/2 directly; this pins that it survives the REAL path —
  # merged into the runtime context by jido's AgentServer, carried through
  # routing, and handed to the action that runs. Before this, an admitted
  # signal reached DeliverReply with no idea who the envelope named, which is
  # what pushes an implementer to dig the principal out of the signal and
  # label it nothing. It also pins the honesty half: these are the ENVELOPE's
  # claims, so they sit under their own key and the verdict wording is
  # unchanged by their presence, and the display name is deliberately absent.
  test "the envelope's own unverified claims reach DeliverReply under context.aph.claims" do
    envelope = Demo.Corpus.example!("principal_signed_envelope.json")
    subject = get_in(JSON.decode!(envelope), ["credentialSubject"])

    run_happy_path!()

    assert_receive {:deliver_reply_ran, _params, context}

    assert context.aph.claims == %{
             envelope_id: JSON.decode!(envelope)["id"],
             human_principal_did: subject["humanPrincipal"]["id"],
             agent_did: subject["agent"]["id"],
             channel_kind: subject["channel"]["kind"]
           }

    assert context.aph.claims.channel_kind == "slack"
    assert context.aph.verdict == @verdict
    refute inspect(context.aph.claims) =~ subject["humanPrincipal"]["displayName"]
  end

  # Why this test exists: PRD-001 §8 makes it a hard rule that the guard's
  # output never contains the bare words "verified" or "signed" — an aph-ex
  # structure pass "says NOTHING about whether any signature verifies", so
  # either word in a transcript would be an overclaim, and §8 says the
  # honesty contract is asserted, not merely written down.
  #
  # It pins "bare word", not "substring": the leg's log DOES contain
  # "PrincipalSigned" (the attestation-mode literal from the spec's closed
  # vocabulary, which the guard must be able to name), and the word-boundary
  # match must let that through while catching a bare "signed". Asserting
  # the compound is present first is what keeps this test honest — an empty
  # log would otherwise pass it trivially.
  test "the happy-path log names PrincipalSigned but never the bare words verified or signed" do
    log = run_happy_path!()

    assert log =~ "PrincipalSigned"

    refute log =~ ~r/\bverified\b/i
    refute log =~ ~r/\bsigned\b/i
  end

  # Why this test exists: D7 puts the golden corpus in a real aph checkout
  # resolved at RUNTIME, and this nested app is exactly where a relative
  # default would silently resolve to the wrong depth. It used to pin a
  # config key of "../../aph"; the corpus now arrives inside the pinned
  # :aph dependency, so what needs pinning is the OPPOSITE — that this app
  # sets NO key and still lands on a real aph checkout from the cwd demo
  # tests and tasks actually run in. A reintroduced hardcoded key fails
  # here, as does a drifted or vendored corpus, before any claim is made
  # about the fixture the PRD names (bodySize 427, agreeing with the bytes
  # on disk).
  test "the corpus resolves through the :aph dependency with no configured path" do
    refute Application.get_env(:jido_aph, :aph_repo_path),
           "demo/config/config.exs must not pin :aph_repo_path — the dependency locates the corpus"

    repo = Demo.Corpus.repo_path!()
    assert File.dir?(Path.join(repo, "examples"))

    body = Demo.Corpus.example!("principal_signed_body.txt")
    assert byte_size(body) == 427

    # Decoded only to read the fixture's own claim about its body — never on
    # the trust path (the envelope crosses every boundary as JSON text).
    envelope = Demo.Corpus.example!("principal_signed_envelope.json")
    communication = get_in(JSON.decode!(envelope), ["credentialSubject", "communication"])

    assert communication["bodySize"] == byte_size(body)
  end
end
