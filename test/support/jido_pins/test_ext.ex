defmodule JidoAph.JidoPins.TestExt do
  @moduledoc """
  Test-only Jido.Signal.Ext shaped like the T4 notarization extension
  (required string field + optional string field), used by the put_extension
  pins. The schema is a NimbleOptions keyword schema — that is what
  `use Jido.Signal.Ext` validates and enforces
  (deps/jido_signal/lib/jido_signal/ext.ex, `NimbleOptions.new!/1` at
  compile time, `NimbleOptions.validate/2` in `validate_data/1`).

  Registration hazard, pinned by the tests: the `@after_compile` hook only
  fires when this module is freshly COMPILED, so on any later `mix test` run
  (cached beam) the registry would not know this namespace. jido's own
  application re-registers its extensions at every boot for exactly this
  reason (deps/jido/lib/jido/application.ex,
  `register_signal_extensions/0`); the pin tests do the same in setup.

  The field names are deliberately PIN-PREFIXED, not envelope_json/body_b64:
  `Jido.Signal.from_map/1` lifts flattened top-level attrs into whichever
  registered extension's SCHEMA FIELD NAMES match first, in registry key
  order (deps/jido_signal/lib/jido_signal.ex, `inflate_extensions/1` →
  `find_matching_schema_attrs/2`). Two registered extensions sharing a field
  name therefore steal each other's lifts — observed live in this suite when
  this ext briefly shared field names with the T4 notarization extension.
  """

  use Jido.Signal.Ext,
    namespace: "aph.pintest.v1",
    schema: [
      pin_envelope_json: [type: :string, required: true],
      pin_body_b64: [type: :string]
    ]
end
