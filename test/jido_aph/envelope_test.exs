defmodule JidoAph.EnvelopeTest do
  use ExUnit.Case, async: true

  # Why this file exists: `JidoAph.Guard` ran the four-op gate and then threw
  # the result away — it bound `{:ok, _normalized}` from
  # APH.parse_envelope_json/1 and discarded it — so no check the guard might
  # grow could read a single envelope field. JidoAph.Envelope is that missing
  # read side, and it carries ONE decision that must not be re-litigated per
  # check: the parity rule. A second parser is allowed to read the NIF's
  # normalized OUTPUT and is never allowed to read the wire bytes, because
  # serde_json must stay the only adjudicator of unknown fields, duplicate
  # keys and the untagged `proof` union. Every test below pins either that
  # rule or the read-only contract that rides on it.

  alias JidoAph.Corpus
  alias JidoAph.Envelope
  alias JidoAph.Guard

  @moduletag capture_log: true

  defp goldens do
    Corpus.repo_path!()
    |> Path.join("examples/*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.sort()
  end

  defp normalized!(name) do
    {:ok, normalized} = APH.parse_envelope_json(Corpus.example!(name))
    normalized
  end

  defp envelope!(name) do
    {:ok, envelope} = Envelope.from_normalized(normalized!(name))
    envelope
  end

  # Why: the whole corpus, not one fixture. The card's claim is that decoding
  # aph-ex's normalized output yields every field the later binding checks
  # need, and that claim is only worth anything if it holds for all twelve
  # goldens — twelve channel kinds, two attestation modes, one envelope with
  # an extra `appleAurAcceptance` member under credentialSubject. It also pins
  # the premise that makes "normalized only" a real distinction rather than a
  # slogan: the normalized bytes are NOT the wire bytes (they are hundreds of
  # bytes shorter), so a reader can tell at a glance which side of the rule a
  # call site is on.
  test "every golden's normalized output decodes, and normalized bytes differ from the wire bytes" do
    names = goldens()
    assert length(names) == 12

    for name <- names do
      raw = Corpus.example!(name)
      {:ok, normalized} = APH.parse_envelope_json(raw)

      refute normalized == raw,
             "#{name}: normalized output is byte-identical to the wire bytes, " <>
               "which would make the parity rule untestable"

      assert {:ok, envelope} = Envelope.from_normalized(normalized)
      assert is_map(envelope)

      # Fields every conformant envelope carries (§7.1.1, §7.1.2).
      assert is_binary(Envelope.id(envelope)), "#{name}: no id"
      assert is_binary(Envelope.issuer(envelope)), "#{name}: no issuer"
      assert is_binary(Envelope.valid_from(envelope)), "#{name}: no validFrom"
      assert is_binary(Envelope.valid_until(envelope)), "#{name}: no validUntil"
      assert is_binary(Envelope.human_principal_did(envelope)), "#{name}: no principal DID"
      assert is_binary(Envelope.agent_did(envelope)), "#{name}: no agent DID"
      assert is_binary(Envelope.channel_kind(envelope)), "#{name}: no channel kind"
      assert is_map(Envelope.recipient_addressing(envelope)), "#{name}: no addressing"
      assert is_binary(Envelope.content_class(envelope)), "#{name}: no contentClass"
      assert is_binary(Envelope.body_sha256(envelope)), "#{name}: no bodySha256"
    end
  end

  # Why: an accessor that quietly reinterpreted a value would poison every
  # check built on top of it, so each one is pinned against the literal path
  # in the document rather than against a remembered constant. The golden is
  # the PrincipalSigned fixture the demo's happy path uses, and its values are
  # read here from the same bytes the accessors read.
  test "each accessor returns the document's own value at its documented path" do
    envelope = envelope!("principal_signed_envelope.json")
    decoded = JSON.decode!(normalized!("principal_signed_envelope.json"))

    assert Envelope.id(envelope) == decoded["id"]
    assert Envelope.issuer(envelope) == decoded["issuer"]
    assert Envelope.valid_from(envelope) == decoded["validFrom"]
    assert Envelope.valid_until(envelope) == decoded["validUntil"]

    subject = decoded["credentialSubject"]

    assert Envelope.human_principal_did(envelope) == subject["humanPrincipal"]["id"]

    assert Envelope.human_principal_display_name(envelope) ==
             subject["humanPrincipal"]["displayName"]

    assert Envelope.agent_did(envelope) == subject["agent"]["id"]
    assert Envelope.channel_kind(envelope) == subject["channel"]["kind"]
    assert Envelope.recipient_addressing(envelope) == subject["channel"]["recipientAddressing"]

    assert Envelope.recipient_addressing(envelope, "channelId") ==
             subject["channel"]["recipientAddressing"]["channelId"]

    assert Envelope.content_class(envelope) == subject["communication"]["contentClass"]
    assert Envelope.body_sha256(envelope) == subject["communication"]["bodySha256"]
    assert Envelope.attestation_mode(envelope) == subject["policy"]["attestationMode"]

    # And the values are what the fixture really is, so a silently-empty
    # accessor cannot pass the equalities above by returning nil twice.
    assert Envelope.channel_kind(envelope) == "slack"
    assert Envelope.attestation_mode(envelope) == "PrincipalSigned"
    assert Envelope.recipient_addressing(envelope, "channelId") == "C01234567"
  end

  # Why: `nil` is this module's whole answer for "absent", and a later binding
  # check must read it as a REFUSAL rather than skip itself — which only works
  # if absence is really reported as nil and not defaulted into something
  # plausible. Three absences, each real in the corpus: slack_reply carries no
  # attestationMode at all (§7.1.7's normative absence), discord addressing has
  # a userId and no channelId, and no envelope carries an invented field.
  test "absent fields read as nil, never as a default" do
    mode_absent = envelope!("slack_reply_envelope.json")
    assert Envelope.attestation_mode(mode_absent) == nil
    assert Envelope.channel_kind(mode_absent) == "slack"

    discord = envelope!("discord_dm_envelope.json")
    assert Envelope.channel_kind(discord) == "discord"
    assert Envelope.recipient_addressing(discord, "userId") == "123456789012345678"
    assert Envelope.recipient_addressing(discord, "channelId") == nil
    assert Envelope.recipient_addressing(discord, "teamId") == nil
  end

  # Why: an accessor is called mid-gate, inside the `with` that owes the
  # caller `{:error, reason}` and never an exception. Kernel.get_in/2 RAISES
  # when an intermediate node is a non-map term, so the module walks the path
  # itself; this pins that a wrong-shaped node answers nil instead of blowing
  # a hole in the refusal contract.
  test "a wrong-shaped intermediate node answers nil rather than raising" do
    assert Envelope.human_principal_did(%{"credentialSubject" => "not an object"}) == nil
    assert Envelope.channel_kind(%{"credentialSubject" => %{"channel" => 42}}) == nil
    assert Envelope.recipient_addressing(%{}, "channelId") == nil
    assert Envelope.id(%{}) == nil
  end

  # Why: from_normalized/1 is the module's only constructor and its failure
  # branch must behave like the rest of the guard's guard-authored refusals —
  # an actionable message with no APH_E code, because no protocol rule was
  # reached. (Reaching this branch at all means the NIF returned something
  # that is not a JSON object, i.e. an interpreter bug; borrowing a protocol
  # code for that would misattribute it.)
  test "from_normalized refuses non-object input with a code-free, actionable message" do
    assert {:error, reason} = Envelope.from_normalized("[1,2,3]")
    assert reason =~ "rather than a JSON object"
    assert reason =~ "APH.parse_envelope_json/1"
    refute reason =~ "APH_E"

    assert {:error, reason} = Envelope.from_normalized("{not json")
    assert reason =~ "did not decode as JSON"
    refute reason =~ "APH_E"
  end

  # Why: THE parity test — the one that proves the wire bytes are never the
  # thing that gets decoded, using a document where the two parsers genuinely
  # disagree. Golden bytes with a second `"id"` member inserted BEFORE the
  # real one: Elixir's stdlib JSON accepts the document and takes the first
  # spelling (the attacker's), while serde_json refuses it outright with
  # "duplicate field `id`". So a gate that decoded the wire bytes would hand a
  # routed Action a complete, attacker-chosen claims map for a document the
  # reference implementation refuses to parse at all. The guard refuses
  # instead, with serde's message passed through untouched and no context of
  # any kind — which is only possible because the decode reads the NIF's
  # output, which for these bytes never exists.
  test "wire bytes are never the thing decoded: a document Elixir accepts and serde refuses is refused" do
    raw = Corpus.example!("principal_signed_envelope.json")
    real_id = "urn:uuid:00000000-0000-4000-8000-0000000000f3"
    attacker_id = "urn:uuid:ATTACKER"

    duplicated =
      String.replace(
        raw,
        ~s("id": "#{real_id}"),
        ~s("id": "#{attacker_id}",\n  "id": "#{real_id}"),
        global: false
      )

    refute duplicated == raw

    # What the forbidden path would have produced. Handing wire bytes to
    # from_normalized/1 is exactly the misuse the moduledoc forbids; it is
    # spelled out here so the hazard is a value in this file rather than a
    # sentence in a doc.
    assert {:ok, wire_decoded} = Envelope.from_normalized(duplicated)
    assert Envelope.id(wire_decoded) == attacker_id

    # What the only parser on the trust path says about the same bytes.
    assert {:error, "duplicate field `id`" <> _ = parser_message} =
             APH.parse_envelope_json(duplicated)

    signal = Jido.Signal.new!("slack.reply.requested", %{})
    {:ok, signal} = JidoAph.attach_notarization(signal, duplicated)

    assert {:error, ^parser_message} =
             Guard.prepare_signal(signal, %{
               config: %{required: true, require_mode: "PrincipalSigned"}
             })
  end

  # Why: the behavioural test above proves the rule holds for the one call
  # site that exists today; this pins that a second one cannot appear without
  # a reviewer seeing it. Same idiom as identifier_discipline_test.exs — a
  # grep over lib/ sources, because the property is about which code exists,
  # not about what one execution did. Two halves: only JidoAph.Envelope ever
  # calls a JSON decoder, and the guard's single call passes the variable
  # bound from the NIF rather than the extension's wire bytes.
  test "only JidoAph.Envelope decodes JSON under lib/, and the guard decodes only the NIF's output" do
    root = File.cwd!()

    sources =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Map.new(fn path -> {Path.relative_to(path, root), File.read!(path)} end)

    decoders =
      for {path, source} <- sources, String.contains?(source, "JSON.decode"), do: path

    assert decoders == ["lib/jido_aph/envelope.ex"]

    guard = sources["lib/jido_aph/guard.ex"]

    assert guard =~ "{:ok, normalized} <- APH.parse_envelope_json(envelope_json)"
    assert guard =~ "Envelope.from_normalized(normalized)"
    refute guard =~ "from_normalized(envelope_json)"
  end
end
