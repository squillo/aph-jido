defmodule Demo.MixProject do
  use Mix.Project

  # The same aph commit the library pins. Restated rather than read from the
  # library, because a mix.exs cannot depend on the project it depends on:
  # the two must be bumped together, and CI's fixture-drift digests pin the
  # same SHA, so a mismatch fails loudly rather than reading other bytes.
  @aph_ref "9b94ec13b7a5ada079e661e068734736e20ae9eb"

  def project do
    [
      app: :demo,
      version: "0.1.0",
      # Same floor the library declares (jido's own requirement is ~> 1.18);
      # the toolchain actually proven against this repo is recorded in the
      # root README.md.
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Demo.Application, []}
    ]
  end

  defp deps do
    [
      # The library under demonstration (PRD-001 §7.4).
      {:jido_aph, path: ".."},
      # The pinned git dependency, restated from HERE because this app
      # resolves its own deps tree (demo/deps/). Same shape and same ref as
      # the library's; `APH_PATH` overrides both at once (see aph_dep/0).
      aph_dep(),
      # Direct, not incidental: the demo defines agents with Jido.Agent,
      # actions with Jido.Action, and builds/sends signals with
      # Jido.Signal + Jido.AgentServer.
      {:jido, "~> 2.3"},
      {:jido_signal, "~> 2.2"},
      # Declared here as well as in the library, because the CI gate runs for
      # BOTH apps (PRD-001 T15) and `mix deps.audit` scans the lockfile of the
      # project it is invoked in. demo/mix.lock is its own resolution, so it
      # needs its own auditor.
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  # Mirrors the library's aph_dep/0. Default is the pinned git dependency,
  # whose `subdir:` clones the WHOLE aph repository into demo/deps/aph —
  # which is where Demo.Corpus finds examples/ and where the deep leg finds
  # interpreters/typescript. Set APH_PATH to the ROOT of an aph checkout to
  # build both apps against a live working tree instead.
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
          holds examples/ and interpreters/ — not the Elixir interpreter
          inside it. Unset it to fall back to the pinned git dependency:

              unset APH_PATH && mix deps.get
          """
        end

        {:aph, path: path}
    end
  end
end
