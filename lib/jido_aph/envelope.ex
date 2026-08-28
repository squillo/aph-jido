defmodule JidoAph.Envelope do
  @moduledoc """
  Read-only field access over an APH envelope that `aph-ex` has **already
  admitted**.

  `JidoAph.Guard` runs the parity-locked four-op gate and, until now, threw
  the result away: it bound `{:ok, _normalized}` from
  `APH.parse_envelope_json/1` and discarded it, so no check the guard might
  grow — validity window, channel binding, agent-DID binding, replay — could
  read a single field. This module is that missing read side, and nothing
  more. It has no writes, no re-serialization, no struct, and no opinion:
  every function here returns a value the envelope ASSERTS about itself.

  ## The parity rule (the reason this module exists as its own module)

  **Decode only `APH.parse_envelope_json/1`'s normalized output. Never the
  wire bytes.**

  `from_normalized/1` is the sole constructor and its argument is defined as
  the binary that call returned — not the `envelope_json` a signal carried.
  That is the pattern `APH`'s own moduledoc prescribes:

      {:ok, normalized} = APH.parse_envelope_json(received)
      envelope = Jason.decode!(normalized)

  and the reason is a parity property, not a style preference. `serde_json`
  on the Rust side stays the ONLY parser that ever adjudicates unvalidated
  input: it is what denies unknown fields, what refuses a duplicate key, and
  — the sharp one — what decides which arm of the envelope's **untagged**
  `proof` union a document belongs to (a single object is `NotaryAttested`,
  a two-element chain is `PrincipalSigned`). A second parser reading raw
  wire bytes would be a second adjudicator of exactly those questions, and
  two parsers that disagree about one document is how a structural gate
  starts admitting things the reference implementation refuses.

  Reading the normalized OUTPUT breaks none of that: those bytes are what
  the Rust side emitted after it had already decided every one of those
  questions. This module only re-hydrates a decision that has already been
  made elsewhere.

  It decodes with Elixir's stdlib `JSON` (available since 1.18, which is
  this project's floor), so no dependency is added and `jason` — transitive
  via `jido_signal` — does not become a direct one.

  ## Every value here is the envelope's own claim

  Nothing in this module verifies anything. `human_principal_did/1` returns
  the DID string the document contains; it does not resolve it, does not
  check a signature made with it, and does not assert that the human it
  names approved anything. The same is true of every other accessor. The
  guard surfaces four of these under `context.aph.claims` and labels them
  there for the same reason they are labelled here.

  ## `nil` means ABSENT, and a check must treat it as a refusal

  Accessors return `nil` when the path is not present in the document —
  never a default, never a substitute value. A caller building a check on
  top of one of these MUST treat `nil` as a failure to establish the fact,
  not as a fact that passed. An absent `validUntil` is not an envelope that
  never expires; an absent `recipientAddressing` sub-field is not an
  envelope addressed to everyone. This module cannot enforce that for its
  callers, so it says it here.
  """

  @typedoc """
  A decoded APH envelope: the plain map `from_normalized/1` produced from
  `APH.parse_envelope_json/1`'s output. String keys throughout, exactly as
  the document spells them — this module never atomizes a wire key.
  """
  @type t :: %{optional(String.t()) => term()}

  @doc """
  Decodes `APH.parse_envelope_json/1`'s **normalized output** for field access.

  The argument must be the binary that call returned. Handing this function
  the wire bytes instead would put a second parser on the trust path and
  break the parity rule the moduledoc states — see there for why that
  matters and what it would cost.

  Returns `{:ok, envelope}` or, when the bytes are not a JSON object,
  `{:error, reason}` with a guard-shaped message carrying no `APH_E` code:
  no protocol rule is being applied here, and inventing a code for a decode
  that only ever fails on an interpreter bug would misattribute it.
  """
  @spec from_normalized(binary()) :: {:ok, t()} | {:error, String.t()}
  def from_normalized(normalized) when is_binary(normalized) do
    case JSON.decode(normalized) do
      {:ok, envelope} when is_map(envelope) ->
        {:ok, envelope}

      {:ok, other} ->
        {:error,
         "normalized envelope decoded to #{inspect(other)} rather than a JSON object; " <>
           "refused (this input must be APH.parse_envelope_json/1's output)"}

      {:error, reason} ->
        {:error,
         "normalized envelope did not decode as JSON (#{inspect(reason)}); " <>
           "refused (this input must be APH.parse_envelope_json/1's output)"}
    end
  end

  @doc """
  The envelope's `id` — the unique envelope identifier (§7.1.1).

  Nothing in this library consumes it yet. Replay protection would.
  """
  @spec id(t()) :: String.t() | nil
  def id(envelope), do: dig(envelope, ["id"])

  @doc """
  The envelope's `issuer` (§7.1.1).

  Metadata, and the spec is emphatic about it: "A verifier MUST NOT infer
  the signer from this field — each proof's `verificationMethod` is
  authoritative, and `issuer` is metadata."
  """
  @spec issuer(t()) :: String.t() | nil
  def issuer(envelope), do: dig(envelope, ["issuer"])

  @doc """
  The envelope's `validFrom` as the RFC 3339 string the document spells.

  Returned as text, uncompared and unparsed. This library performs no
  validity-window check; see the guard's checked/not-checked table.
  """
  @spec valid_from(t()) :: String.t() | nil
  def valid_from(envelope), do: dig(envelope, ["validFrom"])

  @doc """
  The envelope's `validUntil` as the RFC 3339 string the document spells.

  Returned as text, uncompared and unparsed, exactly like `valid_from/1`.
  """
  @spec valid_until(t()) :: String.t() | nil
  def valid_until(envelope), do: dig(envelope, ["validUntil"])

  @doc """
  `credentialSubject.humanPrincipal.id` — the DID of the human the envelope
  names as principal.

  A string the document contains. No key was resolved and no signature made
  with it was checked.
  """
  @spec human_principal_did(t()) :: String.t() | nil
  def human_principal_did(envelope),
    do: dig(envelope, ["credentialSubject", "humanPrincipal", "id"])

  @doc """
  `credentialSubject.humanPrincipal.displayName` — the human-readable name
  the envelope carries for its principal.

  Deliberately NOT surfaced in the guard's runtime context: a display name
  is the field most likely to be rendered straight into a UI, and rendering
  an unauthenticated name next to an admitted action is how "the guard
  checked this" gets read into a string nothing checked. Available here for
  a caller that wants it and has decided how to label it.
  """
  @spec human_principal_display_name(t()) :: String.t() | nil
  def human_principal_display_name(envelope),
    do: dig(envelope, ["credentialSubject", "humanPrincipal", "displayName"])

  @doc """
  `credentialSubject.agent.id` — the DID of the agent the envelope names.

  The agent signs nothing in APH v0.1 (§7.1.11 defines exactly two proof
  roles, principal and notary), so this is an unauthenticated assertion even
  in a fully signature-verified envelope.
  """
  @spec agent_did(t()) :: String.t() | nil
  def agent_did(envelope), do: dig(envelope, ["credentialSubject", "agent", "id"])

  @doc """
  `credentialSubject.channel.kind` — the end-delivery medium (§7.1.5).

  The closed vocabulary is not enforced anywhere in this repository, so this
  may be any string the document contains.
  """
  @spec channel_kind(t()) :: String.t() | nil
  def channel_kind(envelope), do: dig(envelope, ["credentialSubject", "channel", "kind"])

  @doc """
  `credentialSubject.channel.recipientAddressing` — the whole addressing map.

  Its sub-fields are channel-specific and the spec treats them as opaque
  (§8.3 step 1), so this returns the map as-is rather than interpreting it.
  """
  @spec recipient_addressing(t()) :: map() | nil
  def recipient_addressing(envelope),
    do: dig(envelope, ["credentialSubject", "channel", "recipientAddressing"])

  @doc """
  One sub-field of `recipientAddressing`, by its wire name.

  `nil` when the envelope carries no addressing map or no such sub-field —
  and per the moduledoc, a binding check must read that `nil` as a refusal
  rather than skip itself.
  """
  @spec recipient_addressing(t(), String.t()) :: term()
  def recipient_addressing(envelope, subfield) when is_binary(subfield),
    do: dig(envelope, ["credentialSubject", "channel", "recipientAddressing", subfield])

  @doc """
  `credentialSubject.communication.contentClass` (§7.1.6).
  """
  @spec content_class(t()) :: String.t() | nil
  def content_class(envelope),
    do: dig(envelope, ["credentialSubject", "communication", "contentClass"])

  @doc """
  `credentialSubject.communication.bodySha256` — the digest the envelope
  claims for the authorized body.

  Returned, never recomputed. Recomputing it would mean hashing on the BEAM,
  which is out of scope for this library; the value here is the document's
  own claim about bytes this library never digests (§8.3 step 8).
  """
  @spec body_sha256(t()) :: String.t() | nil
  def body_sha256(envelope),
    do: dig(envelope, ["credentialSubject", "communication", "bodySha256"])

  @doc """
  `credentialSubject.policy.attestationMode` — the DECLARED mode, or `nil`
  when the document omits it.

  `nil` here is normatively meaningful and is not the same as "unknown": an
  absent `attestationMode` means `NotaryAttested` (§7.1.7). The guard does
  not read this field for its mode gate — `APH.require_attestation_mode/2`
  does, on the Rust side, which is where that normative default lives.
  """
  @spec attestation_mode(t()) :: String.t() | nil
  def attestation_mode(envelope),
    do: dig(envelope, ["credentialSubject", "policy", "attestationMode"])

  # Walks string keys, answering nil the moment the path leaves a map. Written
  # out rather than delegated to Kernel.get_in/2 because get_in/2 RAISES when
  # an intermediate node is a non-map term, and this module's contract is that
  # a read never raises on a shape it did not expect — an accessor that can
  # blow up mid-gate would turn a field read into a crash the refusal contract
  # never covers.
  defp dig(value, []), do: value

  defp dig(map, [key | rest]) when is_map(map), do: dig(Map.get(map, key), rest)

  defp dig(_not_a_map, _path), do: nil
end
