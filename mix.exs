defmodule JidoAph.MixProject do
  use Mix.Project

  # The aph checkout this project builds and tests against. Pinned, never
  # floating: .github/workflows/ci.yml spells the same SHA as `APH_PIN` and
  # re-derives three golden fixture digests from it, so the interpreter and
  # the fixtures are guaranteed to be the same commit. Bumping this is a
  # deliberate reviewed change and must move both places at once.
  @aph_ref "9b94ec13b7a5ada079e661e068734736e20ae9eb"

  def project do
    [
      app: :jido_aph,
      version: "0.1.0",
      # jido's own floor is `~> 1.18`; this project inherits it rather than
      # declaring a newer one nobody has required. The toolchain actually
      # proven against this scaffold is recorded in README.md.
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # test/support holds test-only modules (the T6 corpus loader); they must
  # never compile into the shipped library.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jido, "~> 2.3"},
      # Explicit even though jido brings it transitively: this library defines
      # a Jido.Signal.Ext of its own (PRD-001 D6/T4), so the dependency is
      # direct, not incidental. Never 3.0.0-beta.1 — jido 2.3.x pins ~> 2.2.
      {:jido_signal, "~> 2.2"},
      aph_dep(),
      # Supplies `mix deps.audit`, the last step of the CI gate PRD-001 §4
      # names (T15). The task is NOT in Mix — without this dependency it does
      # not exist, and a gate step that never runs proves nothing. dev/test
      # only and runtime: false, so nothing a consumer ships carries it.
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  # aph-ex is not published to hex.pm, so the `:aph` dependency is fetched from
  # source. There are two shapes, and `APH_PATH` picks between them.
  #
  # THE DEFAULT is the pinned git dependency below, and it is what a reader who
  # clones only THIS repository gets. `subdir:` makes Mix perform a FULL clone
  # of the aph repository into `deps/aph` and then treat `interpreters/elixir`
  # inside it as the dependency's project root. The fullness is the feature,
  # twice over:
  #
  #   * aph-ex's NIF carries a cargo path dependency on `../../../rust/aph-core`,
  #     which resolves only when the rest of the repository is on disk;
  #   * the golden fixture corpus arrives with it at `deps/aph/examples/`, which
  #     is what test/support/corpus.ex reads.
  #
  # PRD-001 D3 recorded that a git dependency could not work here. That was
  # concluded from `sparse:`, which fetches only the named directory and so
  # does break the cargo path — `subdir:` was never tried, and it works. The
  # correction belongs in D3 rather than in a quiet patch; this dependency is
  # the evidence for it. The cost of the wrong conclusion was the first reader
  # outside the project hitting `the dependency is not available`, pointed at a
  # path only a maintainer's machine had, with no remedy in the message.
  #
  # THE ESCAPE HATCH is `APH_PATH`, for a maintainer building against a live aph
  # working tree instead of a pinned checkout. Point it at the repository ROOT —
  # not at `interpreters/elixir` — because test/support/corpus.ex reads the same
  # variable to find `examples/`, so one export moves the dependency and the
  # fixture corpus together:
  #
  #     APH_PATH=/path/to/aph mix test
  #
  # Working this way does not churn the lockfile, which was checked rather than
  # assumed: path dependencies are not locked, so `mix deps.get` under APH_PATH
  # leaves the committed `"aph"` git entry byte-identical and
  # `mix deps.unlock --check-unused` still passes.
  defp aph_dep do
    case System.get_env("APH_PATH") do
      empty when empty in [nil, ""] ->
        {:aph,
         git: "https://github.com/squillo/aph.git", subdir: "interpreters/elixir", ref: @aph_ref}

      root ->
        path = Path.join(root, "interpreters/elixir")

        unless File.dir?(path) do
          raise """
          APH_PATH is set to #{inspect(root)}, but #{path} is not a directory.

          APH_PATH must name the ROOT of an aph checkout — the directory that
          holds examples/ and interpreters/ — not the Elixir interpreter inside
          it. Unset it to fall back to the pinned git dependency:

              unset APH_PATH && mix deps.get
          """
        end

        {:aph, path: path}
    end
  end
end
