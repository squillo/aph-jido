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
  # corpus (PRD-001 §10 gate 4) — if either drifts, the resolved aph checkout
  # moved off the pinned SHA and every downstream claim about the golden envelope
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

  # Why this test exists: it is the regression pin for the defect the first
  # outside reader hit — he cloned this repo alone, `mix deps.get` succeeded,
  # and the build then failed on a sibling `../aph` that only a maintainer's
  # machine had. With no config key and no APH_PATH, the corpus must resolve
  # from the `:aph` DEPENDENCY's own checkout (mix.exs fetches it with
  # `subdir:`, so deps/aph is the whole aph repo, examples/ included). It
  # pins that the resolved root is the one derived from Mix's dependency
  # path — never a hardcoded sibling — and that a golden really loads
  # through it.
  test "with no config and no APH_PATH, the corpus resolves inside the :aph dependency" do
    restore_corpus_env()
    Application.delete_env(:jido_aph, :aph_repo_path)
    System.delete_env("APH_PATH")

    path = JidoAph.Corpus.repo_path!()

    assert File.dir?(Path.join(path, "examples"))
    assert path == Path.expand("../..", Mix.Project.deps_paths()[:aph])
    assert is_binary(JidoAph.Corpus.example!("principal_signed_envelope.json"))
  end

  # Why this test exists: APH_PATH is the maintainer escape hatch, and it is
  # read by mix.exs and by this loader BOTH, so the two must agree that it
  # names the repository ROOT. It pins that precedence: APH_PATH beats the
  # dependency checkout, and an explicitly set :aph_repo_path beats APH_PATH.
  test "APH_PATH names the repo root and an explicit :aph_repo_path outranks it" do
    restore_corpus_env()

    fake = Path.join(System.tmp_dir!(), "jido_aph_corpus_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(fake, "examples"))
    on_exit(fn -> File.rm_rf!(fake) end)

    Application.delete_env(:jido_aph, :aph_repo_path)
    System.put_env("APH_PATH", fake)
    assert JidoAph.Corpus.repo_path!() == fake

    dependency_root = Path.expand("../..", Mix.Project.deps_paths()[:aph])
    Application.put_env(:jido_aph, :aph_repo_path, dependency_root)
    assert JidoAph.Corpus.repo_path!() == dependency_root
  end

  # Why this test exists: D7 chose runtime resolution precisely so a wrong
  # checkout layout fails LOUDLY instead of silently reading the wrong bytes,
  # and the message is the whole remedy a stranger gets. It pins that a bogus
  # :aph_repo_path still raises (an explicitly set key is authoritative — it
  # never falls through to the dependency), and that the message now leads
  # with `mix deps.get` and names both other knobs, rather than telling the
  # reader to go make a sibling clone.
  test "a bogus :aph_repo_path raises loudly, and the message leads with mix deps.get" do
    restore_corpus_env()

    Application.put_env(:jido_aph, :aph_repo_path, "/nonexistent/definitely-not-an-aph-clone")

    err =
      assert_raise RuntimeError, fn ->
        JidoAph.Corpus.example!("principal_signed_envelope.json")
      end

    assert err.message =~ "mix deps.get"
    assert err.message =~ "APH_PATH"
    assert err.message =~ "aph_repo_path"
    assert err.message =~ "/nonexistent/definitely-not-an-aph-clone"
    refute err.message =~ "git clone https://github.com/squillo/aph.git ../aph"
  end

  # Both knobs are process-global, so every test that touches one registers
  # its restoration before mutating anything.
  defp restore_corpus_env do
    previous_config = Application.fetch_env(:jido_aph, :aph_repo_path)
    previous_env = System.get_env("APH_PATH")

    on_exit(fn ->
      case previous_config do
        {:ok, value} -> Application.put_env(:jido_aph, :aph_repo_path, value)
        :error -> Application.delete_env(:jido_aph, :aph_repo_path)
      end

      case previous_env do
        nil -> System.delete_env("APH_PATH")
        value -> System.put_env("APH_PATH", value)
      end
    end)
  end
end
