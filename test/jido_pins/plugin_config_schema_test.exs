defmodule JidoAph.JidoPins.PluginConfigSchemaTest do
  use ExUnit.Case, async: true

  # Why this file exists: PRD-001 T3 names "plugin config schema style (Zoi
  # vs NimbleOptions — docs contradict)" as a blocking ambiguity for the
  # guard's config validation (required/require_mode/depth). Resolved from
  # source, and pinned here: the PLUGIN layer is Zoi end to end —
  # deps/jido/lib/jido/plugin.ex validates `use Jido.Plugin` opts with a Zoi
  # schema, and deps/jido/lib/jido/plugin/config.ex validates per-agent
  # config with Zoi.parse against the plugin's config_schema — while the
  # SIGNAL-EXT layer is NimbleOptions
  # (deps/jido_signal/lib/jido_signal/ext.ex). T7 must write the guard's
  # config_schema in Zoi; T4 must write the extension schema in
  # NimbleOptions keywords.

  alias JidoAph.JidoPins.ConfigProbePlugin

  # Why: pins that per-agent plugin config is validated with
  # Zoi.parse(config_schema, config) and that Zoi defaults are merged in —
  # deps/jido/lib/jido/plugin/config.ex resolve_config!/2. This is the exact
  # seam through which the guard's `require_mode` config will flow.
  #
  # The ensure_loaded! is load-bearing, discovered as a seed-dependent flake:
  # resolve_config/2 probes the schema with
  # `function_exported?(plugin_module, :config_schema, 0)` WITHOUT loading
  # the module (deps/jido/lib/jido/plugin/config.ex, get_config_schema/1),
  # and function_exported? is false for a not-yet-loaded module — so on a
  # lazily-loading VM the config passes through UNVALIDATED and UNDEFAULTED.
  # Agent compilation avoids this only because the agent macro runs
  # Code.ensure_compiled on every plugin first (deps/jido/lib/jido/agent.ex,
  # __validate_plugin_module__/1). Any direct caller of resolve_config —
  # T7's tests included — must ensure the plugin module is loaded first.
  test "per-agent config is Zoi-validated and Zoi defaults are applied" do
    {:module, ConfigProbePlugin} = Code.ensure_loaded(ConfigProbePlugin)

    assert Jido.Plugin.Config.resolve_config!(
             ConfigProbePlugin,
             %{require_mode: "PrincipalSigned"}
           ) == %{require_mode: "PrincipalSigned", log: true}
  end

  # Why: pins WHERE bad guard config fails: Instance.new/1
  # (deps/jido/lib/jido/plugin/instance.ex) calls resolve_config!/2, which
  # raises ArgumentError "Config validation failed" on a Zoi error — and
  # agent modules run Instance.new at COMPILE time
  # (deps/jido/lib/jido/agent.ex, @plugin_instances), so a mis-typed
  # require_mode kills the agent's compilation rather than surfacing at
  # runtime. T7's config tests should assert at this seam.
  test "invalid per-agent config raises at the Instance.new seam agents compile through" do
    assert_raise ArgumentError, ~r/Config validation failed/, fn ->
      Jido.Plugin.Instance.new({ConfigProbePlugin, %{require_mode: 42}})
    end
  end

  # Why: pins that `use Jido.Plugin` opts themselves are Zoi-validated at
  # compile time — deps/jido/lib/jido/plugin.ex @plugin_config_schema is a
  # Zoi.object and the __using__ macro raises CompileError
  # "Invalid plugin configuration" when Zoi.parse fails (here: a plugin name
  # that fails the validate_plugin_name refinement). The guard module itself
  # is subject to this gate.
  test "invalid `use Jido.Plugin` opts refuse to compile via the Zoi gate" do
    code = """
    defmodule JidoAph.JidoPins.BadNamePlugin do
      use Jido.Plugin,
        name: "bad name!",
        state_key: :bad_name,
        actions: []
    end
    """

    assert_raise CompileError, ~r/Invalid plugin configuration/, fn ->
      Code.compile_string(code)
    end
  end

  # Why: the other half of the style split — pins that Jido.Signal.Ext
  # schemas are NimbleOptions, enforced at compile time by
  # NimbleOptions.new! inside deps/jido_signal/lib/jido_signal/ext.ex
  # __using__ ("Invalid extension schema" CompileError for a schema
  # NimbleOptions rejects). Writing the T4 extension schema in Zoi would not
  # merely misbehave — it would not compile.
  test "an Ext schema NimbleOptions rejects refuses to compile" do
    code = """
    defmodule JidoAph.JidoPins.BadSchemaExt do
      use Jido.Signal.Ext,
        namespace: "aph.pinbadschema.v1",
        schema: [field: [type: :bogus_type]]
    end
    """

    assert_raise CompileError, ~r/Invalid extension schema/, fn ->
      Code.compile_string(code)
    end
  end
end
