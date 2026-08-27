defmodule Demo.Jido do
  @moduledoc """
  The demo's Jido instance (PRD-001 §7.4).

  `use Jido, otp_app: :demo` generates this module's whole surface
  (deps/jido/lib/jido.ex `__using__/1`):

  - `child_spec/1` and `start_link/1`, which hand `Jido.start_link/1` a
    supervisor holding this instance's Task.Supervisor, Registry,
    RuntimeStore and agent DynamicSupervisor (`Jido.init/1`, same file);
  - `start_agent/2` — starts a `Jido.AgentServer` under that
    DynamicSupervisor, returning `DynamicSupervisor.on_start_child()`
    (`Jido.start_agent/3` merges `agent:` and `jido: __MODULE__` into the
    child spec);
  - `stop_agent/1,2` (pid or id) and `whereis/1,2` (id lookup).

  Runtime config, if any, would be read from `config :demo, Demo.Jido`
  (the generated `config/1`); the demo uses the defaults as-is.
  """

  use Jido, otp_app: :demo
end
