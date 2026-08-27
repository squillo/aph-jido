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
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

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
      {:aph, path: "../aph/interpreters/elixir"}
    ]
  end
end
