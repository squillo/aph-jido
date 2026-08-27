defmodule JidoAph.JidoPins.ConfigProbePlugin do
  @moduledoc """
  Test-only plugin with a `config_schema`, shaped like the guard's future
  config (PRD-001 §7.1: `require_mode`), used to pin that per-agent plugin
  config is validated with Zoi — `Zoi.parse(config_schema, config)` in
  deps/jido/lib/jido/plugin/config.ex (`resolve_config!/2`), invoked from
  deps/jido/lib/jido/plugin/instance.ex (`Instance.new/1`), which agent
  modules run at compile time (deps/jido/lib/jido/agent.ex,
  `@plugin_instances`).
  """

  use Jido.Plugin,
    name: "pin_config_probe",
    state_key: :pin_config_probe,
    actions: [],
    config_schema:
      Zoi.object(%{
        require_mode: Zoi.string() |> Zoi.optional(),
        log: Zoi.boolean() |> Zoi.default(true)
      })
end
