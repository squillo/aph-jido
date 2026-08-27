defmodule JidoAph.DeepVerifiers.SeamProbe do
  @moduledoc """
  Test-only implementer of the `JidoAph.DeepVerifier` behaviour, used to
  probe `JidoAph.Guard`'s `depth: :deep` config validation. It verifies
  NOTHING: `verify/2` refuses every envelope unconditionally, which makes
  it impossible to mistake for a real verifier AND turns any admission of
  a signal on a `depth: :deep` agent into proof that the v1 gate never
  invoked the deep verifier (if the gate had called and honored this
  module, everything would refuse).
  """

  @behaviour JidoAph.DeepVerifier

  @impl JidoAph.DeepVerifier
  def verify(_envelope_json, _opts), do: {:error, :seam_probe_never_verifies}
end

defmodule JidoAph.DeepVerifiers.NotAVerifier do
  @moduledoc """
  Test-only module that does NOT implement `JidoAph.DeepVerifier` (no
  `@behaviour`, no `verify/2`), used to pin that the guard's `depth: :deep`
  validation checks the behaviour contract, not mere module existence.
  """

  def not_verify, do: :this_module_implements_nothing
end
