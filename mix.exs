defmodule JidoAph.MixProject do
  use Mix.Project

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
      # Sibling-clone path dep (PRD-001 D1/D3): aph-ex is not on hex.pm, and a
      # sparse git dep provably breaks its NIF's ../../../rust/aph-core path.
      {:aph, path: "../aph/interpreters/elixir"},
      # Supplies `mix deps.audit`, the last step of the CI gate PRD-001 §4
      # names (T15). The task is NOT in Mix — without this dependency it does
      # not exist, and a gate step that never runs proves nothing. dev/test
      # only and runtime: false, so nothing a consumer ships carries it.
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end
end
