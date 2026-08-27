defmodule Demo.DeepVerifier.TsSidecar do
  @moduledoc """
  `JidoAph.DeepVerifier` implemented by shelling out to the sibling `aph`
  clone's TypeScript verifier (PRD-001 D5/T12).

  ## Why this lives here and not in the library

  `JidoAph.DeepVerifier` is a behaviour with no in-library implementation,
  and that absence is load-bearing: `aph-ex`'s four-op surface is
  parity-locked, zero cryptography runs in Elixir, and a deep verifier is
  therefore always someone else's implementation of the spec. This module
  is the demo's choice of that someone — `interpreters/typescript` in the
  sibling clone resolved at runtime (CI pins its SHA; this module does not),
  run under `node` through `priv/node/verify.mjs`.

  ## What the deep leg ADDS over `JidoAph.Guard`

  The guard's structural gate answers "is this notarization-shaped, and
  does its label match its proof carriage" and says nothing about whether
  any signature verifies. Running this module over the same envelope adds
  every check in the guard's not-checked column: both Ed25519 signatures
  over their RFC 8785 canonical §7.2.1 bases, issuance order, the embedded
  delegation mandate's bindings and its two signatures, the validity
  window against a caller-pinned instant, and `bodySha256` recomputed over
  the body bytes as received.

  ## What it STILL does not do

  No network key discovery (§8.4), no revocation transport (§6.3.3), no
  live notary contact. The borrowed verifier's own boundary is stated at
  the top of `interpreters/typescript/src/verify.ts` — it "parses bytes it
  is handed and NEVER fetches", so keys and `now` arrive as parameters.
  Consequently:

  - `:now` is **required**. This module reads no clock either, and neither
    end of the seam will invent one. The golden's window is
    `2026-05-21T00:00:00Z .. 2026-05-22T00:00:00Z`; the aph testkit's own
    pinned instant inside it is `2026-05-21T12:00:00Z`
    (`interpreters/typescript/testkit/golden.ts`,
    `GOLDEN_EVALUATION_INSTANT`).
  - `:keys` is **refused**. The sidecar supplies exactly one key — the
    golden notary's, under `did:web:notary.squillo.com#key-1`, imported
    from the aph repo's published RFC 8032 §7.1 TEST 3 vector (see
    `priv/node/verify.mjs`, which spells the derivation). A demo that let
    a caller hand in arbitrary key material would be pretending to be a
    general-purpose verifier. `did:web:notary.squillo.com` is a fixture
    identifier and is never resolved or contacted.

  ## The result

  `{:ok, map}` on admission. The `:verified` sub-map carries the
  TypeScript `VerifiedEnvelope` field names **verbatim**
  (`attestationMode`, `bodyHashChecked`, `embeddedMandateChecked`, from
  `src/verify.ts`) so a rename upstream surfaces as a failing match here
  instead of being silently absorbed by a translation layer; everything
  this module adds around it is ordinary snake_case. The parsed envelope
  is deliberately not returned — the caller already holds the text, and a
  re-serialization is a second spelling of a signed document.

      %{
        verified: %{
          attestationMode: "PrincipalSigned",
          bodyHashChecked: true,
          embeddedMandateChecked: true
        },
        key_sourcing: %{
          supplied: ["did:web:notary.squillo.com#key-1"],
          supplied_out_of_band: ["did:web:notary.squillo.com#key-1"],
          self_describing: ["did:key:z6Mkia…#z6Mkia…"],
          fetched: []
        },
        transport: %{envelope_bytes: 3382, body_bytes: 427},
        evaluated_at: "2026-05-21T12:00:00Z",
        require_mode: "PrincipalSigned",
        verifier: %{runtime: "v26.3.0", dist: "…/interpreters/typescript/dist"}
      }

  `{:error, map}` otherwise, in three kinds that must not be conflated:

  - `%{kind: :refusal}` — a protocol verdict from the verifier, carrying
    its `:code` (a §11 code, or `nil` for the two failure kinds that
    deliberately have none: strict-parse and key-unavailable) and its
    message byte-for-byte.
  - `%{kind: :unavailable}` — node or the built dist is missing. A setup
    problem, never a verdict about an envelope. See `availability/0`.
  - `%{kind: :sidecar_failure}` — node ran and produced no response
    document. Also never a verdict.

  ## Envelope handling

  `envelope_json` crosses this boundary as JSON TEXT and is handed to the
  verifier unparsed, exactly as it arrived. This module decodes nothing on
  the trust path.
  """

  @behaviour JidoAph.DeepVerifier

  # The TypeScript package declares `engines: {node: ">=20"}`, and the floor
  # is real rather than cautious: every signature check goes through
  # SubtleCrypto, and Ed25519 in `crypto.subtle` is Node 20+.
  @minimum_node_major 20

  @default_timeout_ms 30_000

  @doc """
  Verifies `envelope_json` by running the TypeScript verifier in a node
  subprocess.

  Options:

  - `:now` (required) — RFC 3339 instant to evaluate the validity window
    against.
  - `:require_mode` — `"PrincipalSigned"` or `"NotaryAttested"`; omitted
    when `nil`, in which case whichever mode the structure proves is
    accepted.
  - `:body_bytes` — the authorized body bytes exactly as received. Supply
    them and §8.3 step 8 runs (`bodyHashChecked: true`); omit them and it
    does not.
  - `:aph_repo_path` — override the sibling clone location; defaults to
    `Demo.Corpus.repo_path!/0`.
  - `:timeout` — subprocess wall-clock budget in ms (default
    `#{@default_timeout_ms}`).

  `:keys` is rejected: this sidecar pins its own single-entry key map (see
  the moduledoc).
  """
  @impl JidoAph.DeepVerifier
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def verify(envelope_json, opts) when is_binary(envelope_json) and is_list(opts) do
    if Keyword.has_key?(opts, :keys) do
      raise ArgumentError, """
      #{inspect(__MODULE__)} does not accept caller-supplied :keys.

      It supplies exactly one key — the golden notary's, under
      "did:web:notary.squillo.com#key-1", imported from the aph repo's
      published RFC 8032 §7.1 TEST 3 vector (see priv/node/verify.mjs).
      A demo that accepted arbitrary key material would be presenting
      itself as a general-purpose verifier, which it is not.
      """
    end

    opts =
      Keyword.validate!(opts,
        now: nil,
        require_mode: nil,
        body_bytes: nil,
        aph_repo_path: nil,
        timeout: @default_timeout_ms
      )

    now = Keyword.fetch!(opts, :now)

    unless is_binary(now) do
      raise ArgumentError, """
      #{inspect(__MODULE__)} requires :now, an RFC 3339 instant.

      Neither end of this seam reads a clock. The borrowed verifier states
      the reason in its own VerifyOptions doc ("Required — this module reads
      no clock"): a library that read the wall clock could not be tested
      deterministically. The caller pins the instant and says so out loud.
      """
    end

    with :ok <- availability(opts[:aph_repo_path]) do
      run(envelope_json, now, opts)
    end
  end

  @doc """
  Whether the deep leg can run at all: `:ok`, or `{:error, %{kind:
  :unavailable}}` carrying setup instructions in `:message`.

  Separate from `verify/2` so a caller can degrade with instructions and a
  nonzero exit instead of reporting an environment gap as an envelope
  verdict.
  """
  @spec availability(Path.t() | nil) :: :ok | {:error, map()}
  def availability(aph_repo_path \\ nil) do
    with {:ok, node_bin} <- find_node(),
         :ok <- check_node_version(node_bin),
         {:ok, repo} <- resolve_repo(aph_repo_path) do
      check_dist(repo)
    end
  end

  @doc """
  Absolute path to `priv/node/verify.mjs`, the whole implementation of the
  deep leg.
  """
  @spec script_path() :: Path.t()
  def script_path, do: Path.join([Application.app_dir(:demo, "priv"), "node", "verify.mjs"])

  # -------------------------------------------------------------------
  # Availability
  # -------------------------------------------------------------------

  defp find_node do
    case System.find_executable("node") do
      nil ->
        unavailable(:node_not_found, """
        the deep leg needs node on PATH and none was found.

        The core demo does not: `mix demo.run` and the untagged test suite
        run with no Node at all. This leg is the optional one.

            # macOS
            brew install node
            # or any Node >= #{@minimum_node_major} install
        """)

      path ->
        {:ok, path}
    end
  end

  defp check_node_version(node_bin) do
    version =
      case System.cmd(node_bin, ["--version"], stderr_to_stdout: true) do
        {out, 0} -> String.trim(out)
        {out, status} -> "(`node --version` exited #{status}: #{String.trim(out)})"
      end

    case Integer.parse(String.trim_leading(version, "v")) do
      {major, _rest} when major >= @minimum_node_major ->
        :ok

      _ ->
        unavailable(:node_too_old, """
        node #{version} is below the Node >= #{@minimum_node_major} floor the
        TypeScript implementation declares (`engines` in
        interpreters/typescript/package.json).

        The floor is real: every signature check there runs through
        SubtleCrypto, and Ed25519 in `crypto.subtle` arrived in Node 20.
        """)
    end
  end

  defp resolve_repo(nil) do
    {:ok, Demo.Corpus.repo_path!()}
  rescue
    error in RuntimeError -> unavailable(:aph_clone_missing, Exception.message(error))
  end

  defp resolve_repo(path), do: {:ok, Path.expand(path, File.cwd!())}

  defp check_dist(repo) do
    dist = Path.join([repo, "interpreters", "typescript", "dist"])

    missing =
      Enum.reject(
        [
          Path.join([dist, "src", "verify.js"]),
          Path.join([dist, "src", "didkey.js"]),
          Path.join([dist, "src", "types.js"]),
          Path.join([dist, "testkit", "vectors.js"])
        ],
        &File.regular?/1
      )

    if missing == [] do
      :ok
    else
      unavailable(:dist_missing, """
      the sibling clone's TypeScript build is missing or incomplete.

      Absent: #{Enum.map_join(missing, ", ", &Path.relative_to(&1, repo))}

      `dist/` is a build artifact and is git-ignored upstream, so a fresh
      clone never has one. Build it (this writes only untracked artifacts):

          cd #{Path.join([repo, "interpreters", "typescript"])}
          npm install && npm run build

      `npm install`, not `npm ci`: upstream commits no lockfile, on purpose
      (its own interpreters/typescript/.gitignore spells out the reason), and
      `npm ci` refuses to run without one — so it would fail on exactly the
      fresh clone this message exists to serve.

      The build must include testkit/, which is where the notary's
      published RFC 8032 §7.1 TEST 3 key material is imported from; the
      upstream tsconfig.json already includes it.
      """)
    end
  end

  defp unavailable(reason, message),
    do: {:error, %{kind: :unavailable, reason: reason, message: String.trim(message)}}

  # -------------------------------------------------------------------
  # The subprocess
  # -------------------------------------------------------------------

  defp run(envelope_json, now, opts) do
    {:ok, node_bin} = find_node()
    {:ok, repo} = resolve_repo(opts[:aph_repo_path])

    dir = Path.join(System.tmp_dir!(), "jido_aph_deep_#{System.unique_integer([:positive])}")
    request_path = Path.join(dir, "request.json")
    response_path = Path.join(dir, "response.json")

    File.mkdir_p!(dir)

    try do
      # The envelope rides inside the request as a JSON STRING and is
      # reconstructed by `JSON.parse` on the other side, so the bytes
      # `verifyEnvelope` sees are the bytes handed to this function. The
      # response reports the length it measured; the test suite asserts it
      # against `byte_size/1` here, which is a transport-integrity check
      # that needs no hashing.
      File.write!(
        request_path,
        JSON.encode!(%{
          "aphRepoPath" => repo,
          "envelope" => envelope_json,
          "now" => now,
          "requireMode" => opts[:require_mode],
          "bodyB64" => opts[:body_bytes] && Base.encode64(opts[:body_bytes])
        })
      )

      {output, status} =
        System.cmd(node_bin, [script_path(), request_path, response_path],
          stderr_to_stdout: true,
          cd: dir
        )

      case File.read(response_path) do
        {:ok, body} -> decode_response(body, now, opts)
        {:error, _} -> sidecar_failure(status, output)
      end
    after
      File.rm_rf(dir)
    end
  end

  defp decode_response(body, now, opts) do
    case JSON.decode(body) do
      {:ok, %{"ok" => true} = response} ->
        {:ok, admitted(response, now, opts)}

      {:ok, %{"ok" => false} = response} ->
        {:error,
         %{
           kind: :refusal,
           error: response["errorName"],
           code: response["code"],
           message: response["message"]
         }}

      {:error, _} ->
        sidecar_failure(nil, body)
    end
  end

  defp admitted(response, now, opts) do
    %{"verified" => verified, "keySourcing" => keys, "transport" => transport} = response

    %{
      # Upstream's own field names, unrenamed on purpose (see moduledoc).
      verified: %{
        attestationMode: verified["attestationMode"],
        bodyHashChecked: verified["bodyHashChecked"],
        embeddedMandateChecked: verified["embeddedMandateChecked"]
      },
      key_sourcing: %{
        supplied: keys["supplied"],
        supplied_out_of_band: keys["suppliedOutOfBand"],
        self_describing: keys["selfDescribing"],
        fetched: keys["fetched"]
      },
      transport: %{
        envelope_bytes: transport["envelopeBytes"],
        body_bytes: transport["bodyBytes"]
      },
      evaluated_at: now,
      require_mode: opts[:require_mode],
      verifier: %{
        runtime: get_in(response, ["verifier", "runtime"]),
        dist: get_in(response, ["verifier", "dist"])
      }
    }
  end

  defp sidecar_failure(status, output) do
    {:error,
     %{
       kind: :sidecar_failure,
       exit_status: status,
       output: output,
       message:
         "the node sidecar produced no response document; this is a tooling failure, " <>
           "not a verdict about the envelope"
     }}
  end
end
