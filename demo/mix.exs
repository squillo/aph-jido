defmodule Demo.MixProject do
  use Mix.Project

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
      # Sibling-clone path dep, restated from HERE: this app sits one level
      # deeper than the library, so the relative path grows a level. Mix
      # converges it with the library's own "../aph/interpreters/elixir"
      # because both expand to the same absolute checkout.
      {:aph, path: "../../aph/interpreters/elixir"},
      # Direct, not incidental: the demo defines agents with Jido.Agent,
      # actions with Jido.Action, and builds/sends signals with
      # Jido.Signal + Jido.AgentServer.
      {:jido, "~> 2.3"},
      {:jido_signal, "~> 2.2"}
    ]
  end
end
