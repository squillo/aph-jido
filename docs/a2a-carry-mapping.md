# The A2A carry mapping: how a jido signal carries what A2A metadata carries

**jido signals are the rail here, not A2A HTTP.** Nothing in this repo
serves or fetches an AgentCard, speaks JSON-RPC `message/send`, or opens a
network connection. The jido signal extension `aph.notarization.v1` mirrors
the A2A carry pattern for APH notarization envelopes so that a reader who
knows one rail can read the other — and this document is the mapping between
them, derived from a **pinned byte-level test**
(`test/jido_aph/signal/ext/notarization_wire_shape_test.exs`), not from
framework documentation, because jido_signal's serialized extension shape is
undocumented upstream.

Upstream sources cited throughout (paths in the sibling `aph` clone):

- `spec/a2a-extension.md` — the pinned extension URI (§2), the
  `AgentExtension` descriptor and its `required` field (§3), the discovery
  and refusal flow (§5).
- `examples/a2a-database-change/a2a-message-send.json` — the wire
  precedent: an envelope riding `Message.metadata` under the URI key.

## 1. Two identifiers, one meaning

| Rail | Identifier | Travels on the wire? |
| --- | --- | --- |
| A2A: `Message.metadata` key (extension URI) | `aph://extensions/notarization/v1` | **Yes** — it *is* the metadata key |
| jido: signal extension namespace | `aph.notarization.v1` | **No** — binds only via the receiver's extension registry |

The URI is pinned in `spec/a2a-extension.md` §2: compared byte-for-byte,
opaque, never dereferenced, declared as a single string constant and never
built from substrings. jido extension namespaces must match
`^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)*$`, which forbids `:` and `/`, so the
URI itself cannot be the namespace. Both identifiers live as single
constants in `JidoAph.Signal.Ext.Notarization` (`a2a_uri/0`,
`namespace/0`); a self-grep test pins the exactly-once property.

## 2. The pinned jido wire shape

Serializing a signal that carries the extension (default `JsonSerializer`;
`Jido.Signal.serialize/1`) produces this frame — these exact bytes are
asserted in the wire-shape test:

```json
{"body_b64":"Qk9EWQ==","envelope_json":"{\"pin\":\"not an envelope\"}","id":"wire-shape-pin-0001","jido_schema_version":1,"source":"/scribe","specversion":"1.0.2","type":"slack.reply.requested"}
```

What the pinned bytes say:

- **Extension fields flatten to top level.** `envelope_json` and (when a
  body travels) `body_b64` are ordinary top-level members of the frame.
  There is **no `"extensions"` wrapper and no namespace key** — the wire
  carries *neither* identifier from §1. (`Jido.Signal.flatten_extensions/1`
  merges each extension's attrs into the core map;
  `deps/jido_signal/lib/jido_signal.ex`.)
- **The envelope is one escaped JSON string value.** It stays JSON text end
  to end — attached as text, escaped into the frame as a single string
  member, byte-identical after deserialize. It is never decoded and
  re-serialized on the carry path.
- **Body bytes are base64, verbatim, in a dedicated field.** No body means
  the `body_b64` key is *absent* (not `null`, not `""`).
- **`jido_schema_version: 1`** is stamped by the serializer
  (`deps/jido_signal/lib/jido_signal/serialization/json_serializer.ex`).
- **Nil optional core fields are omitted** (`time`, `subject`, `data`,
  `datacontenttype`, `dataschema`, `jido_dispatch`).
- **The frame is not byte-canonical.** Member order is stable within a VM
  instance but can differ between VM instances: the extension's atom-keyed
  members come first in atom-table creation order (unspecified by OTP),
  then the string-keyed core members in bytewise order. The pinned test
  therefore pins *both* observed permutations plus an order-independent
  exact member set. Consequence: **never hash, sign, or byte-compare the
  frame.** APH binds the envelope text and the body bytes; the carry frame
  binds nothing — the same lesson the A2A precedent's `bodyRef.note`
  teaches about re-serialization.

Receiver-side facts, equally load-bearing:

- **Deserialize lifts by schema field name.** `Jido.Signal.deserialize/1`
  inflates top-level members back into extension data by matching the
  *schema field names* of every registered extension
  (`inflate_extensions/1` in `deps/jido_signal/lib/jido_signal.ex`), first
  match in registry order wins. Any signal whose frame has a top-level
  `envelope_json` member gets vacuumed into this extension on a VM where it
  is registered — and a second registered extension sharing a field name
  competes for the lift, so extension authors must not reuse these names.
- **An unregistered receiver silently loses the notarization.** jido_signal
  registers extensions from an `@after_compile` hook, which a warm `_build`
  never fires. On a VM where `aph.notarization.v1` is not registered,
  nothing lifts `envelope_json`/`body_b64`, and the wire-schema validation
  then **strips them silently** (`unrecognized_keys: :strip` in
  `deps/jido_signal/lib/jido_signal/serialization/schema.ex`). For a guard
  running `required: true` that failure is closed — missing extension means
  refusal — but a naive consumer just loses the envelope with no error.
  Receivers must call `JidoAph.Signal.Ext.Notarization.ensure_registered/0`
  before deserializing; the `JidoAph` attach/read helpers already do.
- **A `jido_schema_version` stowaway survives round-trips.** The
  serializer's stamp is neither a core attr nor a registered namespace, so
  deserialization preserves it as an *opaque extension*:
  `Jido.Signal.list_extensions/1` on a received signal returns
  `["aph.notarization.v1", "jido_schema_version"]`. Pinned by test. A
  bridge must never blind-forward "all extensions" (see §4).

## 3. The A2A wire precedent

`examples/a2a-database-change/a2a-message-send.json` carries the envelope in
a JSON-RPC `message/send` request:

```json
"metadata": {
  "aph://extensions/notarization/v1": {
    "envelope": "<the full contents of envelope.json, inline>",
    "bodyRef": {
      "partIndex": 1,
      "note": "… A real deployment must transport the authorized bytes verbatim (for example base64 in a dedicated field) and the server MUST hash the bytes it received, never a re-serialization of the parsed object …"
    }
  }
}
```

The metadata value under the URI key is an object with the envelope inline
and a `bodyRef` locating the authorized bytes among the message parts — and
the precedent's own note warns that referencing a re-serializable part is
the trap: bytes must travel verbatim. The jido carry's `body_b64` field *is*
the "dedicated field" that note calls for.

## 4. The mapping table

Derived from the pinned frame in §2 and the precedent in §3:

| Fact carried | jido signal rail (pinned by test) | A2A rail (spec + precedent) |
| --- | --- | --- |
| Which extension this is | Receiver-registry binding of namespace `aph.notarization.v1`; the identifier does not travel | `Message.metadata` key `aph://extensions/notarization/v1`; the identifier is the key (`spec/a2a-extension.md` §2) |
| The envelope | Top-level `envelope_json` member — one escaped JSON string, envelope text verbatim | `metadata[uri].envelope` — envelope inline (precedent) |
| Authorized body bytes | Top-level `body_b64` member — base64 of the received bytes, verbatim; absent key = no body traveled | `metadata[uri].bodyRef` points at a message part; the note requires verbatim transport in a real deployment — `body_b64` realizes that requirement |
| "You must present notarization" | `JidoAph.Guard` config `required: true` → reject and log the envelope-less signal | AgentCard `AgentExtension required: true`; recipient policy REQUIRES → reject and log (`spec/a2a-extension.md` §3, §5) |
| Envelope-less traffic under a permissive policy | Guard `required: false` → pass through tagged unverified | §5 permissive flow: "Not notarized" indicator, deliver under existing trust rules |
| Support discovery | Compile-time: the mounted plugin and registered extension are the deployment's declaration | Runtime: scan `agent_card.extensions[]` for the URI (§5) — no AgentCard exists on the jido rail |

Structural differences a bridge must handle deliberately:

- **Nesting.** A2A groups envelope + body reference into one object under
  the URI key; jido flattens two members into the frame with no grouping
  key at all. A jido→A2A bridge must *construct* the metadata object from
  `JidoAph.read_notarization/1` output and key it by
  `JidoAph.Signal.Ext.Notarization.a2a_uri()` — never by forwarding the
  deserialized extensions map wholesale, which would leak the
  `jido_schema_version` stowaway and key the data by namespace instead of
  URI.
- **Envelope form.** The precedent inlines the envelope document; the jido
  rail deliberately carries it as a JSON *string* so no boundary ever
  parses and re-serializes it — two JSON texts that parse equal can hash
  differently, and the signatures bind bytes, not meaning. A bridge going
  to A2A may inline the text it holds; a bridge coming from A2A must
  capture the envelope's exact bytes, not a re-serialization of a parsed
  object.

## 5. What carrying asserts

Nothing. On either rail, the presence of the extension is transport, not
verification: it makes no claim that the envelope parses, that its proof
structure matches its label, or that any signature verifies. Checks are the
consumer's job — structural gating in `JidoAph.Guard`, cryptographic
verification only in an independent deep verifier outside this library.
