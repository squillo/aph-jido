defmodule JidoAph.Signal.Ext.NotarizationTest do
  use ExUnit.Case, async: true

  alias JidoAph.Signal.Ext.Notarization

  # Any JSON text exercises the carry: the extension is a rail, not a
  # checkpoint — envelope validity is the guard's job (PRD-001 T5/T6 with the
  # golden corpus), so these tests deliberately use a minimal JSON text and
  # make no claim it is a real APH envelope.
  @envelope_json ~s({"aph":"not-a-real-envelope","n":1})

  defp signal! do
    {:ok, signal} = Jido.Signal.new("slack.reply.requested", %{text: "hello"})
    signal
  end

  test "attach/read round-trip preserves envelope JSON text and body bytes byte-for-byte" do
    # Why this test: the envelope must cross the signal boundary as JSON TEXT
    # (PRD-001 §7.2 — the untagged proof union is decided by the bytes). Pins
    # that read_notarization returns the exact binary that was attached,
    # proving no decode/re-encode happened on the carry path, and that
    # body_b64 travels verbatim beside it.
    body_b64 = Base.encode64("authorized bytes, exactly as received")

    {:ok, signal} =
      JidoAph.attach_notarization(signal!(), @envelope_json, body_b64: body_b64)

    assert %{envelope_json: envelope, body_b64: ^body_b64} = JidoAph.read_notarization(signal)
    assert envelope === @envelope_json
  end

  test "attach without :body_b64 stores no body key at all" do
    # Why this test: body_b64 is optional with no default — pins that the
    # validated extension data omits the key entirely (readers must Map.get
    # it, never pattern-match it as required), keeping "no body traveled"
    # distinguishable from any present value.
    {:ok, signal} = JidoAph.attach_notarization(signal!(), @envelope_json)

    assert %{envelope_json: @envelope_json} == JidoAph.read_notarization(signal)
  end

  test "extension data missing envelope_json is rejected" do
    # Why this test: envelope_json is the extension's one required field and
    # the helper API makes omitting it unrepresentable, so this pins the
    # schema gate on the raw put_extension path (the only way a consumer
    # could smuggle envelope-less data in) and that the refusal names the
    # missing field.
    Notarization.ensure_registered()

    assert {:error, reason} =
             Jido.Signal.put_extension(signal!(), Notarization.namespace(), %{
               body_b64: Base.encode64("x")
             })

    assert reason =~ "envelope_json"
  end

  test "a non-string envelope is rejected through the helper" do
    # Why this test: the trust path carries JSON text only — pins that
    # attach_notarization refuses a decoded map (the tempting wrong shape)
    # instead of storing it, per the JSON-in/JSON-out boundary discipline.
    assert {:error, reason} = JidoAph.attach_notarization(signal!(), %{"decoded" => "map"})
    assert reason =~ "envelope_json"
  end

  test "an explicit nil :body_b64 is rejected, not silently dropped" do
    # Why this test: attach_notarization documents that a nil body is a
    # caller bug that must fail at attach time — pins the schema rejection so
    # an upstream encoding bug cannot surface later as a missing-body mystery
    # in the deep-verification leg.
    assert {:error, reason} =
             JidoAph.attach_notarization(signal!(), @envelope_json, body_b64: nil)

    assert reason =~ "body_b64"
  end

  test "attach_notarization raises on unknown options" do
    # Why this test: a misspelled option (say :body) silently dropping the
    # authorized bytes would be a carry bug — pins that unknown option keys
    # raise instead of being ignored.
    assert_raise ArgumentError, fn ->
      JidoAph.attach_notarization(signal!(), @envelope_json, body: "oops")
    end
  end

  test "an unregistered namespace is rejected by put_extension" do
    # Why this test: the helpers depend on put_extension consulting the
    # extension registry — pins that an unregistered namespace is refused
    # outright (the registry gate is real, not a blind map write), which is
    # what makes the single-constant namespace discipline load-bearing.
    assert {:error, "Unknown extension: " <> _} =
             Jido.Signal.put_extension(signal!(), "aph.notarization.v0", %{
               envelope_json: @envelope_json
             })
  end

  test "read_notarization returns nil for a signal with no notarization extension" do
    # Why this test: downstream policy (guard required: false, PRD-001 §7.1)
    # distinguishes "no envelope presented" from every other outcome — pins
    # nil as the absent-extension contract of read_notarization.
    assert JidoAph.read_notarization(signal!()) == nil
  end

  test "ensure_registered registers the extension in a registry that missed it, idempotently" do
    # Why this test: jido_signal registers extensions only from an
    # @after_compile hook, which a warm _build never fires — a fresh VM
    # provably starts with this namespace absent from the registry. Pins that
    # ensure_registered (called by every helper) fills that gap and that
    # repeating it is harmless, the property attach/read correctness rests on.
    assert :ok = Notarization.ensure_registered()
    assert {:ok, Notarization} = Jido.Signal.Ext.Registry.get(Notarization.namespace())
    assert :ok = Notarization.ensure_registered()
    assert {:ok, Notarization} = Jido.Signal.Ext.Registry.get(Notarization.namespace())
  end
end
