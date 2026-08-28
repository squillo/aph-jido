defmodule JidoAph.Corpus do
  @moduledoc """
  Test-support loader for the golden fixture corpus that ships inside the
  `:aph` dependency (PRD-001 D7/T6).

  Signed fixtures are never text-edited and never copied into this repo:
  every golden is read from a real, SHA-pinned aph checkout at RUNTIME.
  Resolution happens inside each function call — never at compile time —
  because a compile-time `Path.expand` at the wrong depth is the
  documented silent-failure gotcha D7 exists to avoid.

  ## Where the checkout comes from

  Three sources, in this precedence:

    1. `Application.get_env(:jido_aph, :aph_repo_path)`, when explicitly
       set. Authoritative — if it is set and wrong, this module raises
       rather than quietly resolving somewhere else.
    2. The `APH_PATH` environment variable, when set. `mix.exs` reads the
       same variable to point the `:aph` dependency at a live working
       tree, so one export moves the dependency and the corpus together.
       It names the aph repository ROOT, not `interpreters/elixir`.
    3. Otherwise the dependency's own checkout. `mix.exs` fetches `:aph`
       as `git:` + `subdir: "interpreters/elixir"`, which clones the WHOLE
       aph repository — `examples/` included — into `deps/aph`. A bare
       clone of this repository therefore has the corpus after
       `mix deps.get`, with no sibling clone anywhere.

  Nothing here hardcodes `"deps/aph"`. The path comes from
  `Mix.Project.deps_paths()`, which answers for the project that is
  actually running: this library resolves `./deps/aph`, and a nested app
  such as `demo/` resolves `demo/deps/aph`. A literal `"deps/aph"` would
  be wrong for one of the two.

  Under every supported shape the dependency's project root is
  `interpreters/elixir` INSIDE the repository — the git `subdir:`, an
  `APH_PATH` working tree, and the legacy sibling `path:` alike — so the
  repository root is two levels above it. The `examples/` check below is
  what makes that derivation safe: if it ever stops holding, the loader
  raises with instructions instead of reading the wrong bytes.

  Envelopes cross every boundary as JSON TEXT, so `example!/1` returns raw
  bytes; tests decode only to derive assertions or tamper-variants.
  """

  @doc """
  The resolved aph repo path, validated to look like an aph clone.

  Resolves config, then `APH_PATH`, then the `:aph` dependency's checkout
  (see the moduledoc), expanding relative candidates against `File.cwd!()`
  at call time. Raises with the full remedy when the winning candidate has
  no `examples/` corpus directory.
  """
  @spec repo_path!() :: Path.t()
  def repo_path!() do
    {source, candidate} = candidate()
    path = candidate && Path.expand(candidate, File.cwd!())

    unless path && File.dir?(Path.join(path, "examples")) do
      raise unavailable_message(source, candidate, path)
    end

    path
  end

  @doc """
  Reads `examples/<name>` from the resolved aph checkout, returning raw bytes.

  Envelope fixtures come back as verbatim JSON text — the form in which an
  APH envelope crosses every boundary. Raises (via `repo_path!/0`) when no
  checkout resolves, or `File.Error` when the checkout exists but the named
  fixture does not.
  """
  @spec example!(String.t()) :: binary()
  def example!(name) do
    repo_path!() |> Path.join("examples") |> Path.join(name) |> File.read!()
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

  # The aph repository root, derived from wherever Mix put the :aph dependency.
  # `Mix.Project.deps_paths/0` needs a project on the stack; it always has one
  # under `mix test`, but a rescue here turns any surprise into this module's
  # instructive raise rather than a Mix internal error.
  defp dependency_checkout do
    case Mix.Project.deps_paths() do
      %{aph: dep_path} -> Path.expand("../..", dep_path)
      _no_aph_dep -> nil
    end
  rescue
    _ -> nil
  end

  defp unavailable_message(source, candidate, path) do
    """
    jido_aph cannot find the aph fixture corpus.

    Looked for:   #{if path, do: Path.join(path, "examples"), else: "(nothing — no candidate path resolved)"}
    Decided by:   #{decided_by(source, candidate)}
    Resolved from cwd #{File.cwd!()}

    This project never vendors signed fixtures; it reads its goldens from a
    real aph checkout. By default that checkout is the `:aph` DEPENDENCY
    itself — mix.exs fetches it as a git dependency with
    `subdir: "interpreters/elixir"`, which clones the WHOLE aph repository,
    examples/ corpus and all, into deps/aph. So the first thing to try is:

        mix deps.get

    To build and test against a live aph working tree instead, point
    APH_PATH at the repository ROOT (the directory holding examples/ and
    interpreters/, NOT interpreters/elixir). mix.exs reads the same
    variable for the dependency, so one export moves both:

        APH_PATH=/path/to/aph mix test

    Or set the config key, which outranks everything above:

        config :jido_aph, aph_repo_path: "/path/to/aph"
    """
  end

  defp decided_by(:config, candidate),
    do: "config :jido_aph, aph_repo_path: #{inspect(candidate)}"

  defp decided_by(:env, candidate), do: "APH_PATH=#{inspect(candidate)}"

  defp decided_by(:dependency, nil),
    do: "the :aph dependency, whose path Mix could not report (run mix deps.get)"

  defp decided_by(:dependency, candidate),
    do: "the :aph dependency checkout at #{inspect(candidate)}"
end
