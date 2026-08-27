defmodule JidoAph.JidoPins.PutExtensionTest do
  use ExUnit.Case, async: true

  # Why this file exists: T4 carries the APH envelope in a registered
  # Jido.Signal.Ext, and PRD-001 leans on put_extension failing loudly for
  # unregistered namespaces. These tests pin the REAL registry-and-validate
  # behavior in deps/jido_signal/lib/jido_signal.ex (put_extension/3,
  # get_extension/2, from_map/1) and
  # deps/jido_signal/lib/jido_signal/ext/registry.ex — including the
  # registration-lifetime gotcha that makes explicit boot-time registration
  # mandatory for any downstream consumer of the T4 extension.

  @moduletag :capture_log

  alias Jido.Signal
  alias Jido.Signal.Ext.Registry
  alias JidoAph.JidoPins.TestExt

  @namespace "aph.pintest.v1"

  setup do
    # Ext auto-registration rides an @after_compile hook, which only fires
    # when the module is freshly compiled — on a cached-beam `mix test` run
    # the registry starts empty of test extensions. jido's own application
    # re-registers at every boot for the same reason
    # (deps/jido/lib/jido/application.ex, register_signal_extensions/0);
    # this setup mirrors that pattern, and the idempotency test below pins
    # that doing so is safe. Registration is VERIFIED, not trusted:
    # Registry.register/1 returns :ok even when it only ENQUEUED the module
    # to a pending list that nothing drains until the registry process next
    # (re)starts (deps/jido_signal/lib/jido_signal/ext/registry.ex, the
    # catch clauses of register/1) — observed once as a full-suite flake, so
    # a boot-time registrant must read back what it registered.
    ensure_registered!()
    :ok
  end

  defp ensure_registered!(attempts_left \\ 100) do
    :ok = Registry.register(TestExt)

    case Registry.get(@namespace) do
      {:ok, TestExt} ->
        :ok

      {:error, :not_found} when attempts_left > 0 ->
        Process.sleep(10)
        ensure_registered!(attempts_left - 1)

      {:error, :not_found} ->
        raise "Ext registry never accepted #{inspect(TestExt)} — register/1 silently deferred"
    end
  end

  # Why: pins the exact refusal T4's tests will rely on. Source:
  # deps/jido_signal/lib/jido_signal.ex put_extension/3 — an unregistered
  # namespace returns {:error, "Unknown extension: " <> namespace} (a STRING,
  # not an error struct), and never touches signal.extensions.
  test "put_extension on an unregistered namespace refuses with the exact string error" do
    signal = Signal.new!("pin.ext", %{})

    assert {:error, "Unknown extension: aph.notregistered.v1"} =
             Signal.put_extension(signal, "aph.notregistered.v1", %{a: 1})
  end

  # Why: pins the registered round-trip shape T4's attach/read helpers wrap:
  # put_extension validates against the ext's NimbleOptions schema
  # (deps/jido_signal/lib/jido_signal/ext.ex validate_data/1 — map in, map
  # out via Enum.to_list/Map.new) and stores the validated ATOM-keyed map
  # under the namespace; get_extension reads it back.
  test "put_extension/get_extension round-trip with a valid atom-keyed map" do
    signal = Signal.new!("pin.ext", %{})
    envelope = ~s({"k":1})

    assert {:ok, signal} =
             Signal.put_extension(signal, @namespace, %{pin_envelope_json: envelope})

    assert Signal.get_extension(signal, @namespace) == %{pin_envelope_json: envelope}
    assert signal.extensions[@namespace] == %{pin_envelope_json: envelope}
  end

  # Why: T4 promises "rejection when envelope_json is missing"; this pins
  # what that rejection actually looks like — a formatted NimbleOptions
  # string naming the missing key (deps/jido_signal/lib/jido_signal/ext.ex
  # validate_data/1 error branch), not an exception and not a tuple code.
  test "put_extension refuses a payload missing the required field, as a string reason" do
    signal = Signal.new!("pin.ext", %{})

    assert {:error, reason} = Signal.put_extension(signal, @namespace, %{pin_body_b64: "aGk="})
    assert is_binary(reason)
    assert reason =~ "pin_envelope_json"
  end

  # Why: the envelope crosses boundaries as JSON text whose maps are
  # string-keyed; this pins that ext DATA must be ATOM-keyed — a string-keyed
  # map is refused (NimbleOptions rejects non-atom keys inside
  # validate_data/1, surfaced through put_extension/3's error branches in
  # deps/jido_signal/lib/jido_signal.ex). T4's helpers must build the atom
  # map themselves rather than pass through decoded JSON.
  test "put_extension refuses a string-keyed payload" do
    signal = Signal.new!("pin.ext", %{})

    assert {:error, _reason} =
             Signal.put_extension(signal, @namespace, %{"pin_envelope_json" => "{}"})
  end

  # Why: pins that READING also consults the registry: get_extension returns
  # nil for an unregistered namespace even when signal.extensions literally
  # holds data under that key (deps/jido_signal/lib/jido_signal.ex
  # get_extension/2 — Registry.get first, map lookup second). A consumer of
  # the T4 extension that never registered it reads nil, silently.
  test "get_extension returns nil for an unregistered namespace even if data is present" do
    signal = Signal.new!("pin.ext", %{})
    smuggled = %{signal | extensions: Map.put(signal.extensions, "aph.notregistered.v1", %{x: 1})}

    assert Signal.get_extension(smuggled, "aph.notregistered.v1") == nil
  end

  # Why: the setup block re-registers on every test; this pins that
  # re-registration of the SAME module is a safe no-op
  # (deps/jido_signal/lib/jido_signal/ext/registry.ex put_extension/3,
  # `existing_module when existing_module == module` clause), so boot-time
  # registration in a downstream app cannot conflict with a fresh compile's
  # @after_compile registration.
  test "registering the same extension module twice is idempotent" do
    assert :ok = Registry.register(TestExt)
    assert :ok = Registry.register(TestExt)
    assert {:ok, TestExt} = Registry.get(@namespace)
  end

  # Why: resolves PRD-001 §12 open item 5 ("whether Signal.new/3 accepts
  # registered extension namespaces as attrs sugar") from source. Pins
  # deps/jido_signal/lib/jido_signal.ex from_map/1 + inflate_extensions/1:
  # the sugar keys on the ext's SCHEMA FIELD NAMES at top level (flattened
  # attrs are lifted into the extension), NOT on the namespace — and a
  # top-level attr keyed by a REGISTERED namespace is silently DROPPED
  # (preserve_unknown_extension/2 keeps only unregistered keys). Both edges
  # justify the PRD's "we spec put_extension regardless". Beware: the lift
  # is first-match-wins across ALL registered extensions in registry key
  # order, which is why this ext's field names are pin-prefixed (see
  # JidoAph.JidoPins.TestExt's moduledoc for the observed collision with
  # the T4 notarization extension).
  test "Signal.new/3 sugar lifts schema-field attrs; a namespace-keyed attr is dropped" do
    assert {:ok, sugared} =
             Signal.new("pin.ext.sugar", %{}, %{pin_envelope_json: ~s({"k":1})})

    assert Signal.get_extension(sugared, @namespace) == %{pin_envelope_json: ~s({"k":1})}

    assert {:ok, dropped} =
             Signal.new("pin.ext.sugar", %{}, %{@namespace => %{pin_envelope_json: "{}"}})

    assert Signal.get_extension(dropped, @namespace) == nil
    refute Map.has_key?(dropped.extensions, @namespace)
  end

  # Why: PRD-001 D6 asserts "the A2A URI cannot be a jido namespace"; this
  # pins the enforcing regex ^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)*$ in
  # deps/jido_signal/lib/jido_signal/ext.ex __using__ — declaring an Ext
  # with the A2A URI as namespace refuses to COMPILE, which is why the URI
  # and the namespace must live as two distinct single-constant identifiers
  # (T4).
  test "an Ext namespace shaped like the A2A URI refuses to compile" do
    code = """
    defmodule JidoAph.JidoPins.UriNamespaceExt do
      use Jido.Signal.Ext, namespace: "aph://extensions/notarization/v1"
    end
    """

    assert_raise CompileError, fn -> Code.compile_string(code) end
  end
end
