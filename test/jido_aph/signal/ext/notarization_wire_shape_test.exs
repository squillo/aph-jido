defmodule JidoAph.Signal.Ext.NotarizationWireShapeTest do
  use ExUnit.Case, async: true

  alias JidoAph.Signal.Ext.Notarization

  # jido_signal's serialized extension shape is UNDOCUMENTED (PRD-001 §7.2,
  # §12 item 5): Jido.Signal.serialize/1 runs the default JsonSerializer,
  # which calls Jido.Signal.flatten_extensions/1
  # (deps/jido_signal/lib/jido_signal.ex) and then Jason-encodes the result
  # with an added "jido_schema_version" => 1
  # (deps/jido_signal/lib/jido_signal/serialization/json_serializer.ex,
  # prepare_for_serialization/1). This file pins what those bytes ACTUALLY
  # are, so docs/a2a-carry-mapping.md derives its mapping table from a green
  # test instead of doc guesses, and a jido_signal point release that shifts
  # the shape breaks here first.

  # Any JSON text exercises the carry — the extension is a rail, not a
  # checkpoint (envelope validity is the guard's job) — so the byte-pin
  # tests use a minimal JSON text whose escaped form stays readable inside
  # the pinned literal. The golden-corpus test below carries a real envelope.
  @envelope_json ~S({"pin":"not an envelope"})

  # The exact bytes Jido.Signal.serialize/1 produced for the fixed signals
  # below, captured from live runs and pinned as literals (never computed
  # in the test — computing the expectation with the code under test would
  # pin nothing). Note what the shape says: extension fields sit at TOP
  # LEVEL, there is no "extensions" wrapper, neither the namespace nor the
  # A2A URI appears anywhere, the envelope is ONE escaped JSON string value,
  # and nil optional core fields (time/subject/data/datacontenttype/
  # dataschema/jido_dispatch) are omitted entirely.
  #
  # WHY TWO PERMUTATIONS: the frame is NOT byte-canonical. flatten_extensions
  # merges the extension's ATOM-keyed attrs into the string-keyed core map,
  # and Erlang flatmap iteration puts atom keys first in atom-table CREATION
  # order — unspecified by OTP and observed to differ between VM instances
  # (`mix run` yields body_b64-first, `mix test` envelope_json-first, each
  # stable within its VM). The string-keyed core members always follow in
  # bytewise order. Exactly these two whole-frame byte strings are possible;
  # any third (new member, wrapper, reordered core keys) fails loudly.
  @pinned_wire_body_first ~S({"body_b64":"Qk9EWQ==","envelope_json":"{\"pin\":\"not an envelope\"}","id":"wire-shape-pin-0001","jido_schema_version":1,"source":"/scribe","specversion":"1.0.2","type":"slack.reply.requested"})
  @pinned_wire_envelope_first ~S({"envelope_json":"{\"pin\":\"not an envelope\"}","body_b64":"Qk9EWQ==","id":"wire-shape-pin-0001","jido_schema_version":1,"source":"/scribe","specversion":"1.0.2","type":"slack.reply.requested"})
  @pinned_wire_no_body ~S({"envelope_json":"{\"pin\":\"not an envelope\"}","id":"wire-shape-pin-0002","jido_schema_version":1,"source":"/scribe","specversion":"1.0.2","type":"slack.reply.requested"})

  # Deterministic signal: Jido.Signal.from_map/1 (unlike new/1) injects no
  # generated id and no wall-clock time, so every serialized byte is fixed.
  defp fixed_signal!(id) do
    {:ok, signal} =
      Jido.Signal.from_map(%{
        "type" => "slack.reply.requested",
        "source" => "/scribe",
        "id" => id,
        "specversion" => "1.0.2"
      })

    signal
  end

  test "serialize/1 emits exactly the pinned bytes for a signal carrying envelope + body" do
    # Why this test: THE byte-level pin PRD-001 T5 exists for. Asserts the
    # entire serialized binary against pinned literals — the only two
    # whole-frame byte strings the current shape can produce (see the
    # permutation note on the attributes) — so any drift in
    # flatten_extensions' shape — field placement, the jido_schema_version
    # stamp, nil-field omission, core-key ordering — is a loud test failure,
    # not silent staleness in docs/a2a-carry-mapping.md. Also pins that the
    # frame is stable WITHIN a VM: repeated serialization is byte-identical,
    # so the nondeterminism is strictly per-VM-instance.
    {:ok, signal} =
      JidoAph.attach_notarization(fixed_signal!("wire-shape-pin-0001"), @envelope_json,
        body_b64: "Qk9EWQ=="
      )

    assert {:ok, wire} = Jido.Signal.serialize(signal)
    assert wire in [@pinned_wire_body_first, @pinned_wire_envelope_first]

    assert {:ok, ^wire} = Jido.Signal.serialize(signal)
  end

  test "the top-level member set of the wire frame is exactly the pinned shape" do
    # Why this test: the byte pin above conflates shape and member order. If
    # it ever breaks, this order-independent pin says WHICH changed: it
    # decodes the frame (the signal frame, never the envelope — that value
    # is asserted as an opaque string) and requires exact map equality, so
    # a new member, a lost member, an "extensions" wrapper, or a namespace
    # key appearing all fail here too, while a pure reordering only fails
    # the byte pin.
    {:ok, signal} =
      JidoAph.attach_notarization(fixed_signal!("wire-shape-pin-0001"), @envelope_json,
        body_b64: "Qk9EWQ=="
      )

    assert {:ok, wire} = Jido.Signal.serialize(signal)

    assert Jason.decode!(wire) == %{
             "body_b64" => "Qk9EWQ==",
             "envelope_json" => @envelope_json,
             "id" => "wire-shape-pin-0001",
             "jido_schema_version" => 1,
             "source" => "/scribe",
             "specversion" => "1.0.2",
             "type" => "slack.reply.requested"
           }
  end

  test "serialize/1 omits the body_b64 key entirely when no body traveled" do
    # Why this test: body_b64 is optional with no default, and
    # flatten_extensions rejects nil-valued attrs — pins that "no body" is
    # the ABSENCE of the key on the wire (not null, not empty string), so
    # receivers can distinguish "no body traveled" from any present value.
    # With a single atom-keyed member there is no permutation ambiguity, so
    # this frame pins as ONE literal (atom key first, string-keyed core
    # members after it in bytewise order — both facts observed identical
    # across VM instances).
    {:ok, signal} =
      JidoAph.attach_notarization(fixed_signal!("wire-shape-pin-0002"), @envelope_json)

    assert {:ok, wire} = Jido.Signal.serialize(signal)
    assert wire === @pinned_wire_no_body
  end

  test "the golden envelope crosses the wire as one escaped JSON string, byte-identical after round-trip" do
    # Why this test: the byte pins above use a toy payload; this proves the
    # REAL golden (aph examples/principal_signed_envelope.json, read at
    # runtime from the SHA-pinned sibling clone) survives serialize →
    # deserialize byte-for-byte — envelope as JSON TEXT the whole way, body
    # bytes verbatim (sha256 recomputed over the round-tripped bytes equals
    # the recorded fixture digest), and neither the jido namespace nor the
    # A2A URI ever appears on the wire (the carry mapping in
    # docs/a2a-carry-mapping.md rests on exactly these facts).
    envelope = JidoAph.Corpus.example!("principal_signed_envelope.json")
    body = JidoAph.Corpus.example!("principal_signed_body.txt")
    body_b64 = Base.encode64(body)

    {:ok, signal} =
      JidoAph.attach_notarization(fixed_signal!("wire-shape-golden-0001"), envelope,
        body_b64: body_b64
      )

    assert {:ok, wire} = Jido.Signal.serialize(signal)

    # The envelope rides as ONE JSON string value: its Jason-escaped form
    # appears verbatim after the top-level key. (Encoding the text to build
    # the needle is not decoding the envelope — the trust path still only
    # ever sees the original bytes.)
    assert String.contains?(wire, ~S("envelope_json":) <> Jason.encode!(envelope))

    # Neither identifier is on the wire — the namespace binds only via the
    # receiver's extension registry, the URI only via the documented mapping.
    refute String.contains?(wire, Notarization.namespace())
    refute String.contains?(wire, Notarization.a2a_uri())
    refute String.contains?(wire, ~S("extensions"))

    assert {:ok, back} = Jido.Signal.deserialize(wire)
    read = JidoAph.read_notarization(back)

    assert read.envelope_json === envelope
    body_back = Base.decode64!(read.body_b64)
    assert body_back === body
    assert byte_size(body_back) == 427

    assert Base.encode16(:crypto.hash(:sha256, body_back), case: :lower) ==
             "dae0b23f649c05222b955ff4752507c6d85a51e00566da4fea1867e50b3b60cb"
  end

  test "deserialize leaves a jido_schema_version stowaway in extensions" do
    # Why this test: pins an upstream wart consumers WILL trip on — the
    # serializer's "jido_schema_version" => 1 stamp is not a core attr and
    # not a registered namespace, so Jido.Signal.from_map/1
    # (preserve_unknown_extension/2) keeps it as an OPAQUE EXTENSION on
    # every deserialized signal. Receivers enumerating list_extensions/1
    # must not assume only real namespaces appear; read_notarization stays
    # clean regardless. docs/a2a-carry-mapping.md names this because a
    # naive "forward all extensions to A2A metadata" bridge would leak it.
    {:ok, signal} =
      JidoAph.attach_notarization(fixed_signal!("wire-shape-pin-0003"), @envelope_json)

    assert {:ok, wire} = Jido.Signal.serialize(signal)
    assert {:ok, back} = Jido.Signal.deserialize(wire)

    assert back.extensions["jido_schema_version"] == 1
    assert Notarization.namespace() in Jido.Signal.list_extensions(back)
    assert "jido_schema_version" in Jido.Signal.list_extensions(back)
    assert %{envelope_json: @envelope_json} == JidoAph.read_notarization(back)
  end
end
