defmodule JidoAph.IdentifierDisciplineTest do
  use ExUnit.Case, async: true

  alias JidoAph.Signal.Ext.Notarization

  # These literals are this test's grep needles. They live under test/, which
  # sits outside the exactly-once scope (lib/ only), but like every doc
  # occurrence they must byte-match the module's constants — asserted against
  # the runtime values in the last test below, so a drift here fails loudly.
  @a2a_uri "aph://extensions/notarization/v1"
  @namespace "aph.notarization.v1"
  @ext_source "lib/jido_aph/signal/ext/notarization.ex"

  defp lib_sources do
    root = File.cwd!()

    root
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Map.new(fn path -> {Path.relative_to(path, root), File.read!(path)} end)
  end

  defp occurrences(string, substring) do
    string |> String.split(substring) |> length() |> Kernel.-(1)
  end

  defp lib_occurrences(needle) do
    for {path, source} <- lib_sources(),
        (count = occurrences(source, needle)) > 0,
        do: {path, count}
  end

  test "the A2A URI literal appears exactly once under lib/, as a module attribute" do
    # Why this test: a2a-extension.md §2 requires the URI declared as a
    # single string constant, and PRD-001 §7.2 scopes the exactly-once rule
    # to code under lib/ — pins that exactly one lib/ file contains the
    # literal exactly once, and that the one occurrence is the @a2a_uri
    # module-attribute definition itself (the moduledoc mapping table
    # interpolates the attribute rather than respelling it).
    assert lib_occurrences(@a2a_uri) == [{@ext_source, 1}]

    assert lib_sources()[@ext_source] =~
             ~r/^ {2}@a2a_uri "#{Regex.escape(@a2a_uri)}"$/m
  end

  test "the A2A URI is never built from substrings under lib/" do
    # Why this test: a2a-extension.md §2 forbids constructing the URI from
    # substrings at call sites, and verifiers compare byte-for-byte — pins
    # that the URI's distinctive fragments occur exactly once under lib/,
    # i.e. only inside the single full literal, leaving no second fragment
    # anywhere that a call site could concatenate from.
    assert lib_occurrences("aph://") == [{@ext_source, 1}]
    assert lib_occurrences("extensions/notarization") == [{@ext_source, 1}]
  end

  test "the jido namespace literal appears exactly once under lib/, as a module attribute" do
    # Why this test: PRD-001 T4 holds BOTH identifiers to single-constant
    # discipline, not just the URI — pins that the namespace literal is
    # spelled only in its @namespace attribute definition (the `use` line and
    # the JidoAph helpers reach it via the attribute and namespace/0, never
    # by respelling).
    assert lib_occurrences(@namespace) == [{@ext_source, 1}]

    assert lib_sources()[@ext_source] =~
             ~r/^ {2}@namespace "#{Regex.escape(@namespace)}"$/m
  end

  test "the module's runtime identifiers byte-match this test's copies" do
    # Why this test: doc occurrences outside lib/ (README, PRD, this file)
    # must byte-match the constants (a2a-extension.md §2: exact string
    # equality, no normalization) — pins the runtime values a2a_uri/0 and
    # namespace/0 against the needles the greps above searched for, closing
    # the loop so the discipline tests cannot pass while grepping for a
    # drifted spelling.
    assert Notarization.a2a_uri() === @a2a_uri
    assert Notarization.namespace() === @namespace
  end
end
