defmodule Demo.Corpus do
  @moduledoc """
  Demo-side loader for the golden fixture corpus in the sibling `aph`
  clone (PRD-001 D7).

  ## Why this exists next to the library's loader

  The library ships an identical-in-spirit loader at
  `test/support/corpus.ex`, but it is unreachable from here. `jido_aph`
  is consumed as a **path dependency**, and a dependency is compiled
  through its own `elixirc_paths/1`, which adds `test/support` only under
  `:test`. Checked, not assumed: after `mix compile` under both `MIX_ENV=dev`
  and `MIX_ENV=test`, `demo/_build/<env>/lib/jido_aph/ebin/` holds exactly
  `Elixir.JidoAph.beam`, `Elixir.JidoAph.DeepVerifier.beam`,
  `Elixir.JidoAph.Guard.beam` and
  `Elixir.JidoAph.Signal.Ext.Notarization.beam` — no `JidoAph.Corpus` in
  either — and `Code.ensure_loaded?(JidoAph.Corpus)` is `false` inside a
  `mix run` here.

  It also has to live in `lib/`, not in `demo/test/support`: the demo's
  presenting action reads the golden at RUNTIME, and `mix demo.run`
  (PRD-001 T11) is a `Mix.Task`, not a test.

  The duplication is therefore deliberate and narrow — same config key,
  same loud raise, no vendored fixture bytes. Signed fixtures are never
  text-edited and never copied into this repo.

  ## Contract

  Resolves at CALL time (never at compile time — a compile-time
  `Path.expand` at the wrong depth is the documented silent-failure gotcha
  D7 exists to avoid), from three sources in this precedence:

    1. `Application.get_env(:jido_aph, :aph_repo_path)`, when explicitly
       set. Authoritative: set and wrong raises rather than resolving
       somewhere else. This app does NOT set it.
    2. `APH_PATH`, when set. `mix.exs` reads the same variable to point the
       `:aph` dependency at a live working tree, so one export moves the
       dependency and the corpus together. It names the aph repository
       ROOT, not `interpreters/elixir`.
    3. Otherwise the `:aph` dependency's own checkout. The dependency is
       fetched as `git:` + `subdir: "interpreters/elixir"`, which clones
       the WHOLE aph repository — `examples/` included — into
       `demo/deps/aph`. A bare clone therefore has the corpus after
       `mix deps.get`, with no sibling clone anywhere.

  Source 3 is found through `Mix.Project.deps_paths()` rather than a
  hardcoded `"deps/aph"`, because this app and the library each resolve
  their own deps tree and a literal path would be wrong for one of them.
  The dependency's project root is `interpreters/elixir` INSIDE the
  repository, so the repository root is two levels above it; the
  `examples/` check is what makes that derivation safe.

  Envelopes cross every boundary as JSON TEXT, so `example!/1` returns raw
  bytes; callers decode only to derive assertions or tamper-variants,
  never on the trust path.
  """

  @doc """
  The resolved aph repo path, validated to look like an aph clone.

  Expands the configured path against `File.cwd!()` and raises with the
  sibling-clone instruction when the path — or its `examples/` corpus
  directory — is absent.
  """
  @spec repo_path!() :: Path.t()
  def repo_path! do
    {source, candidate} = candidate()
    path = candidate && Path.expand(candidate, File.cwd!())

    unless path && File.dir?(Path.join(path, "examples")) do
      raise unavailable_message(source, candidate, path)
    end

    path
  end

  defp candidate do
    case Application.fetch_env(:jido_aph, :aph_repo_path) do
      {:ok, configured} ->
        {:config, configured}

      :error ->
        case System.get_env("APH_PATH") do
          empty when empty in [nil, ""] -> {:dependency, dependency_checkout()}
          root -> {:env, root}
        end
    end
  end

  # The `:aph` dependency's project root is `interpreters/elixir` inside the
  # aph repository (git `subdir:`, an APH_PATH working tree and a legacy
  # sibling `path:` alike), so the repository root — the thing that holds
  # examples/ — is two levels above it.
  defp dependency_checkout do
    case Mix.Project.deps_paths() do
      %{aph: dep_path} -> Path.expand("../..", dep_path)
      _no_aph_dep -> nil
    end
  rescue
    _ -> nil
  end

  defp unavailable_message(source, candidate, path) do
    looked = if path, do: Path.join(path, "examples"), else: "(nothing to look at)"

    origin =
      case source do
        :config -> "config :jido_aph, aph_repo_path: #{inspect(candidate)}"
        :env -> "APH_PATH=#{inspect(candidate)}"
        :dependency -> "the :aph dependency's own checkout"
      end

    """
    the demo cannot find the aph fixture corpus.

    Looked for:   #{looked}
    Source:       #{origin}
    Resolved from cwd #{File.cwd!()}

    Golden envelopes are read from a real aph checkout — this repo never
    vendors signed fixtures. The usual fix is simply to fetch the pinned
    dependency, which carries the whole aph repository including examples/:

        mix deps.get

    To work against a live aph tree instead, point APH_PATH at its ROOT
    (the directory holding examples/ and interpreters/):

        APH_PATH=/path/to/aph mix deps.get

    An explicit `config :jido_aph, aph_repo_path: "/absolute/path"` still
    wins over both, and is what this message reports when it is set.
    """
  end

  @doc """
  Reads `examples/<name>` from the sibling aph clone, returning raw bytes.

  Envelope fixtures come back as verbatim JSON text — the form in which an
  APH envelope crosses every boundary. Raises (via `repo_path!/0`) when
  the clone is absent, or `File.Error` when the clone exists but the named
  fixture does not.
  """
  @spec example!(String.t()) :: binary()
  def example!(name) do
    repo_path!() |> Path.join("examples") |> Path.join(name) |> File.read!()
  end
end
