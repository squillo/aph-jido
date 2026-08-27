defmodule JidoAph.DeepVerifierTest do
  use ExUnit.Case, async: true

  # Why this file exists: PRD-001 T8 — JidoAph.DeepVerifier is a behaviour
  # ONLY, the seam between this library's structural gate and the
  # cryptographic deep leg that lives OUTSIDE it (TS sidecar / Rust
  # sidecar). These tests pin the seam's shape: the exact callback the
  # sidecar cards (T12) must implement, the typespec vocabulary the opts
  # share, and the discipline that no module under lib/ ever implements it
  # — the parity lock means zero cryptography runs in Elixir, and an
  # in-library implementer appearing would be a design change, not a patch.

  # Why: pins the behaviour's single callback as verify/2 exactly — the
  # contract T12's Demo.DeepVerifier.TsSidecar implements and the guard's
  # depth: :deep validation checks (function_exported?(mod, :verify, 2)).
  # A second callback or a changed arity breaks every implementer.
  test "the behaviour declares exactly verify/2" do
    assert JidoAph.DeepVerifier.behaviour_info(:callbacks) == [verify: 2]
  end

  # Why: "the behaviour compiles with typespecs" (T8 DONE) — the callback
  # spec and the verify_opt type must survive to the compiled beam, so
  # Dialyzer and implementers see the documented opts vocabulary
  # (:body_bytes, :now, :require_mode, :keys), not just prose.
  test "callback spec and verify_opt type survive to the compiled beam" do
    assert {:ok, callbacks} = Code.Typespec.fetch_callbacks(JidoAph.DeepVerifier)
    assert [{{:verify, 2}, [_spec]}] = callbacks

    assert {:ok, types} = Code.Typespec.fetch_types(JidoAph.DeepVerifier)
    assert Enum.any?(types, fn {kind, {name, _, _}} -> kind == :type and name == :verify_opt end)
  end

  # Why: "with no in-library implementation" (T8 DONE, PRD §7.1) — both
  # implementation routes live outside this library and the parity lock
  # stays untouched. Swept over the shipped sources themselves (lib/**,
  # the same self-grep style as test/jido_aph/identifier_discipline_test.exs)
  # so an implementer sneaking into the library fails here first.
  test "no module under lib/ implements the behaviour" do
    implementers =
      Path.wildcard(Path.join(File.cwd!(), "lib/**/*.ex"))
      |> Enum.filter(fn path ->
        File.read!(path) =~ "@behaviour JidoAph.DeepVerifier"
      end)

    assert implementers == []
  end

  # Why: the seam works from the OUTSIDE — a module declaring @behaviour
  # and exporting verify/2 (here the test-only SeamProbe) is exactly what
  # the guard's depth: :deep validation accepts, closing the loop between
  # this behaviour and its one in-repo reference.
  test "an external implementer satisfies the contract the :deep validation checks" do
    {:module, mod} = Code.ensure_loaded(JidoAph.DeepVerifiers.SeamProbe)

    behaviours =
      mod.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    assert JidoAph.DeepVerifier in behaviours
    assert function_exported?(mod, :verify, 2)
    assert {:error, :seam_probe_never_verifies} = mod.verify("{}", now: "2026-05-21T12:00:00Z")
  end
end
