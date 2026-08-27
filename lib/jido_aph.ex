defmodule JidoAph do
  @moduledoc """
  APH-notarized signals for jido agents.

  The consumer-facing surface for carrying APH notarization envelopes on
  jido signals: `attach_notarization/3` and `read_notarization/1`, thin
  wrappers over `Jido.Signal.put_extension/3` / `get_extension/2` with the
  extension identifiers held in `JidoAph.Signal.Ext.Notarization` (single
  constants, never respelled here).

  Nothing in this module makes any verification claim: attaching or reading
  an envelope says nothing about whether it parses, whether its proof
  structure matches its label, or whether any signature verifies.
  """

  alias JidoAph.Signal.Ext.Notarization

  @doc """
  Attaches an APH notarization envelope to a signal.

  The envelope travels as JSON text, exactly as given — it is never decoded
  or re-serialized on this path. Authorized body bytes may travel with it,
  base64-encoded verbatim, via the `:body_b64` option.

  ## Options

  - `:body_b64` — base64 of the authorized body bytes exactly as received.
    Must be a string when given; an explicit `nil` is rejected by the
    extension schema rather than silently dropped, so an upstream encoding
    bug fails here instead of surfacing as a confusing downstream refusal.

  ## Returns

  `{:ok, signal}` with the extension attached, or `{:error, reason}` when
  the extension data fails schema validation (for example a non-string
  envelope). Attaching asserts nothing about the envelope's validity.
  """
  @spec attach_notarization(Jido.Signal.t(), String.t(), keyword()) ::
          {:ok, Jido.Signal.t()} | {:error, String.t()}
  def attach_notarization(%Jido.Signal{} = signal, envelope_json, opts \\ []) do
    opts = Keyword.validate!(opts, [:body_b64])
    Notarization.ensure_registered()

    data =
      case Keyword.fetch(opts, :body_b64) do
        {:ok, body_b64} -> %{envelope_json: envelope_json, body_b64: body_b64}
        :error -> %{envelope_json: envelope_json}
      end

    Jido.Signal.put_extension(signal, Notarization.namespace(), data)
  end

  @doc """
  Reads the APH notarization extension from a signal.

  Returns the extension data as validated at attach time — a map with
  `:envelope_json` (JSON text, byte-identical to what was attached) and,
  when body bytes travel with the envelope, `:body_b64` — or `nil` when the
  signal carries no notarization extension. Reading asserts nothing about
  the envelope's validity.
  """
  @spec read_notarization(Jido.Signal.t()) ::
          %{required(:envelope_json) => String.t(), optional(:body_b64) => String.t()} | nil
  def read_notarization(%Jido.Signal{} = signal) do
    Notarization.ensure_registered()
    Jido.Signal.get_extension(signal, Notarization.namespace())
  end
end
