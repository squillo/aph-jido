defmodule JidoAph.JidoPins.CollidingPlugin do
  @moduledoc """
  Test-only plugin that deliberately claims the reserved default-plugin state
  key `:__identity__` (deps/jido/lib/jido/agent/identity/plugin.ex). This
  module compiles fine on its own; the collision only fires when an agent
  mounts it WITHOUT disabling the identity default plugin — the duplicate
  state_key CompileError pin (deps/jido/lib/jido/agent.ex,
  `@duplicate_keys` check) compiles such an agent at runtime and asserts the
  raise.
  """

  use Jido.Plugin,
    name: "pin_identity_squatter",
    state_key: :__identity__,
    actions: []
end
