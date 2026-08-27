defmodule JidoAph.JidoPins.DefaultPluginsTest do
  use ExUnit.Case, async: true

  # Why this file exists: PRD-001 T3 requires proof that jido's framework
  # default plugins (:__thread__/:__identity__/:__memory__) cannot interfere
  # with a mounted guard plugin's state_key or hook chain. Pinned from
  # source: deps/jido/lib/jido/agent/default_plugins.ex (package defaults +
  # overrides) and deps/jido/lib/jido/agent.ex (@all_plugin_decls ordering,
  # @duplicate_keys CompileError, __build_initial_state__/__mount_plugins__).

  alias JidoAph.JidoPins.{BareAgent, DownstreamPlugin, ProbeAgent, ProbePlugin}

  # Why: pins the composition rule the guard's hook position depends on —
  # deps/jido/lib/jido/agent.ex `@all_plugin_decls @default_plugin_list ++
  # (plugins || [])`: the three package defaults
  # (deps/jido/lib/jido/agent/default_plugins.ex @package_defaults) are
  # declared FIRST, so their (identity) hooks run before the guard's, and
  # their reserved state_keys sit alongside — never inside — the guard's.
  test "default plugins are declared first, with their reserved state_keys" do
    modules = Enum.map(ProbeAgent.plugin_specs(), & &1.module)

    assert modules == [
             Jido.Thread.Plugin,
             Jido.Agent.Identity.Plugin,
             Jido.Memory.Plugin,
             ProbePlugin,
             DownstreamPlugin
           ]

    assert Enum.map(ProbeAgent.plugin_specs(), & &1.state_key) == [
             :__thread__,
             :__identity__,
             :__memory__,
             :pin_probe,
             :pin_downstream
           ]
  end

  # Why: pins state non-interference at mount time. The mounted plugin's Zoi
  # schema defaults are seeded under ITS state_key
  # (deps/jido/lib/jido/agent.ex __build_initial_state__/1), while the three
  # default plugins declare no schema and mount {:ok, nil}
  # (deps/jido/lib/jido/thread/plugin.ex, agent/identity/plugin.ex,
  # memory/plugin.ex), so Agent.new/0 leaves the guard's slice exactly its
  # own — the defaults contribute NOTHING to it.
  test "a mounted plugin's state slice is seeded from its own schema, untouched by defaults" do
    agent = ProbeAgent.new()

    assert agent.state[:pin_probe] == %{seen: 0}
  end

  # Why: pins the collision guard that protects the guard's state_key in the
  # other direction — a plugin claiming a default's reserved state_key
  # (:__identity__) while defaults are enabled is a COMPILE error
  # ("Duplicate plugin state_keys", deps/jido/lib/jido/agent.ex
  # @duplicate_keys check), not a silent overwrite.
  test "claiming a default plugin's state_key refuses to compile" do
    code = """
    defmodule JidoAph.JidoPins.DupStateKeyAgent do
      use Jido.Agent,
        name: "pin_dup_agent",
        plugins: [JidoAph.JidoPins.CollidingPlugin]
    end
    """

    assert_raise CompileError, ~r/Duplicate plugin state_keys/, fn ->
      Code.compile_string(code)
    end
  end

  # Why: pins the documented escape hatch T7 may need for a minimal demo
  # agent — `default_plugins: false` removes ALL framework defaults
  # (deps/jido/lib/jido/agent/default_plugins.ex
  # apply_agent_overrides(_, false) -> []), leaving only the mounted
  # plugins.
  test "default_plugins: false leaves only the agent's own plugins" do
    assert Enum.map(BareAgent.plugin_specs(), & &1.module) == [ProbePlugin]
  end
end
