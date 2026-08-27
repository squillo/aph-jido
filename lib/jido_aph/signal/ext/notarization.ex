defmodule JidoAph.Signal.Ext.Notarization do
  # Single-constant identifier discipline (PRD-001 §7.2; a2a-extension.md §2:
  # reference implementations MUST declare the URI as a single string constant
  # and MUST NOT construct it from substrings at call sites). Each identifier
  # below is spelled exactly once under lib/ — the moduledoc mapping table and
  # every call site interpolate or call these, never respell them. A self-grep
  # test pins the exactly-once property.
  @a2a_uri "aph://extensions/notarization/v1"
  @namespace "aph.notarization.v1"

  @moduledoc """
  The jido signal extension that carries an APH notarization envelope.

  ## What this extension asserts: nothing

  Carrying an envelope is not verifying it. Attaching this extension makes
  no claim that the envelope parses, that its proof structure matches its
  label, that any signature verifies, or that any policy is satisfied.
  Structural checks belong to `JidoAph.Guard`; cryptographic verification
  belongs to a deep verifier outside this library. This module is a rail,
  not a checkpoint.

  ## Identifier mapping (one meaning, two rails)

  The A2A extension carries the envelope inline under a `Message.metadata`
  key equal to the pinned extension URI (`spec/a2a-extension.md` in the aph
  repo, byte-exact string equality, no normalization). jido signal extension
  namespaces must match `^[a-z][a-z0-9]*(?:\\.[a-z][a-z0-9]*)*$`
  (`Jido.Signal.Ext.__using__/1`), which forbids `:` and `/`, so the URI
  itself cannot be the namespace. The two identifiers map byte-exactly:

  | Rail                                        | Identifier      |
  | ------------------------------------------- | --------------- |
  | A2A `Message.metadata` key (extension URI)  | `#{@a2a_uri}`   |
  | jido signal extension namespace             | `#{@namespace}` |

  Both identifiers live in exactly one module attribute each, in this
  module; consumers reach them through `a2a_uri/0` and `namespace/0`.

  ## Fields

  - `envelope_json` (required, string) — the APH envelope as JSON text. The
    envelope crosses every boundary as text: the untagged proof union is
    decided by the bytes, and two JSON texts that parse equal can hash
    differently, so nothing on the trust path may decode and re-serialize
    it (aph spec §8.3).
  - `body_b64` (optional, string) — the authorized body bytes, base64 of
    the exact bytes as received. `bodySha256` is only ever recomputed over
    these bytes, never over a re-serialization (aph spec §8.3 step 8).
  """

  use Jido.Signal.Ext,
    namespace: @namespace,
    schema: [
      envelope_json: [
        type: :string,
        required: true,
        doc: "APH envelope as JSON text; never decoded on the trust path."
      ],
      body_b64: [
        type: :string,
        doc: "Authorized body bytes, base64 of the exact received bytes."
      ]
    ]

  @doc """
  The pinned A2A extension URI, byte-identical to the constant in the aph
  repo's `spec/a2a-extension.md` §2. Compare with exact string equality;
  the URI is opaque in v0.1 and must not be dereferenced.
  """
  @spec a2a_uri() :: String.t()
  def a2a_uri, do: @a2a_uri

  @doc """
  Idempotently registers this extension with `Jido.Signal.Ext.Registry`.

  jido_signal registers extensions from an `@after_compile` hook queued into
  `:persistent_term`, which only fires when this module is actually compiled.
  A warm `_build` loads the cached `.beam` without compiling, so a fresh VM
  can start with this namespace absent from the registry — and
  `Jido.Signal.put_extension/3` / `get_extension/2` both refuse or return
  `nil` for unregistered namespaces. The `JidoAph` helpers call this before
  every registry-dependent operation; it is a single registry read when
  already registered.
  """
  @spec ensure_registered() :: :ok
  def ensure_registered do
    case Jido.Signal.Ext.Registry.get(@namespace) do
      {:ok, _module} -> :ok
      {:error, :not_found} -> Jido.Signal.Ext.Registry.register(__MODULE__)
    end
  end
end
