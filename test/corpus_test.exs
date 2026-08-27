defmodule JidoAph.CorpusTest do
  # async: false — the bogus-path test mutates the global Application env
  # that every other test in this module (and any future corpus consumer)
  # reads at runtime.
  use ExUnit.Case, async: false

  @golden_body_sha256 "dae0b23f649c05222b955ff4752507c6d85a51e00566da4fea1867e50b3b60cb"

  # Why this test exists: the whole fixture discipline (PRD-001 §10 gate 4)
  # hangs on the corpus loader actually reaching the sibling clone's golden
  # PrincipalSigned envelope. It pins that principal_signed_envelope.json
  # loads as raw JSON text, that the text JSON-parses, and that it is the
  # envelope the PRD says it is (attestationMode "PrincipalSigned" under
  # credentialSubject.policy) — decoding here derives a test assertion only;
  # the envelope itself always travels as text.
  test "principal_signed_envelope.json loads and JSON-parses" do
    text = JidoAph.Corpus.example!("principal_signed_envelope.json")
    assert is_binary(text)

    decoded = JSON.decode!(text)
    assert is_map(decoded)

    assert get_in(decoded, ["credentialSubject", "policy", "attestationMode"]) ==
             "PrincipalSigned"
  end

  # Why this test exists: T10's refusal-matrix row 3 (mode-absent envelope
  # against a PrincipalSigned policy -> APH_E012) consumes this exact
  # fixture, so the loader must serve it before that card can build. It pins
  # that slack_reply_envelope.json loads and JSON-parses AND that its policy
  # really carries no attestationMode key — absent normatively means
  # NotaryAttested (spec §7.1.7), which is the whole point of row 3.
  test "slack_reply_envelope.json loads, JSON-parses, and is mode-absent" do
    text = JidoAph.Corpus.example!("slack_reply_envelope.json")
    assert is_binary(text)

    decoded = JSON.decode!(text)
    assert is_map(decoded)

    policy = get_in(decoded, ["credentialSubject", "policy"])
    assert is_map(policy)
    refute Map.has_key?(policy, "attestationMode")
  end

  # Why this test exists: bodySize 427 and the recorded golden hash pin the
  # corpus (PRD-001 §10 gate 4) — if either drifts, the sibling clone moved
  # off the pinned SHA and every downstream claim about the golden envelope
  # is unattributable. It recomputes BOTH sides at runtime: sha256 over the
  # body bytes actually read from disk, and the binding actually extracted
  # from the envelope JSON — then pins both to the recorded constant.
  test "principal_signed_body.txt is 427 bytes and matches the envelope's body binding" do
    body = JidoAph.Corpus.example!("principal_signed_body.txt")
    assert byte_size(body) == 427

    recomputed_sha256 =
      :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    envelope =
      JidoAph.Corpus.example!("principal_signed_envelope.json") |> JSON.decode!()

    communication = get_in(envelope, ["credentialSubject", "communication"])

    assert recomputed_sha256 == @golden_body_sha256
    assert communication["bodySha256"] == recomputed_sha256
    assert communication["bodySize"] == byte_size(body)
  end

  # Why this test exists: D7 chose runtime config precisely so a wrong
  # checkout layout fails LOUDLY instead of silently resolving a
  # compile-time path to the wrong depth. It pins that a bogus
  # :aph_repo_path raises with the sibling-clone instruction (the clone
  # command and the config key both named) rather than surfacing as a
  # confusing File.Error deeper in the loader.
  test "a bogus :aph_repo_path raises loudly with the sibling-clone instruction" do
    previous = Application.fetch_env(:jido_aph, :aph_repo_path)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_aph, :aph_repo_path, value)
        :error -> Application.delete_env(:jido_aph, :aph_repo_path)
      end
    end)

    Application.put_env(:jido_aph, :aph_repo_path, "/nonexistent/definitely-not-an-aph-clone")

    err =
      assert_raise RuntimeError, fn ->
        JidoAph.Corpus.example!("principal_signed_envelope.json")
      end

    assert err.message =~ "SIBLING CLONE"
    assert err.message =~ "git clone https://github.com/squillo/aph.git ../aph"
    assert err.message =~ "aph_repo_path"
  end
end
