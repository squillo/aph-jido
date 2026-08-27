defmodule Demo.Corpus do
  @moduledoc """
  Demo-side loader for the golden fixture corpus in the sibling `aph`
  clone (PRD-001 D7).

  ## Why this exists next to the library's loader

  The library ships an identical-in-spirit loader at
  `test/support/corpus.ex`, but it is unreachable from here. `jido_aph`
  is consumed as a **path dependency**, and a dependency is compiled
  through its own `elixirc_paths/1`, which adds `test/support` only under
  `:test`. Checked, not assumed: after `mix compile` under both `MIX_ENV=dev`
  and `MIX_ENV=test`, `demo/_build/<env>/lib/jido_aph/ebin/` holds exactly
  `Elixir.JidoAph.beam`, `Elixir.JidoAph.DeepVerifier.beam`,
  `Elixir.JidoAph.Guard.beam` and
  `Elixir.JidoAph.Signal.Ext.Notarization.beam` — no `JidoAph.Corpus` in
  either — and `Code.ensure_loaded?(JidoAph.Corpus)` is `false` inside a
  `mix run` here.

  It also has to live in `lib/`, not in `demo/test/support`: the demo's
  presenting action reads the golden at RUNTIME, and `mix demo.run`
  (PRD-001 T11) is a `Mix.Task`, not a test.

  The duplication is therefore deliberate and narrow — same config key,
  same loud raise, no vendored fixture bytes. Signed fixtures are never
  text-edited and never copied into this repo.

  ## Contract

  Reads `Application.get_env(:jido_aph, :aph_repo_path, "../aph")` at CALL
  time (never at compile time — a compile-time `Path.expand` at the wrong
  depth is the documented silent-failure gotcha D7 exists to avoid). This
  app sets the key to `"../../aph"` in `config/config.exs` because demo
  tasks and tests run with `File.cwd!() == demo/`.

  Envelopes cross every boundary as JSON TEXT, so `example!/1` returns raw
  bytes; callers decode only to derive assertions or tamper-variants,
  never on the trust path.
  """

  @doc """
  The resolved aph repo path, validated to look like an aph clone.

  Expands the configured path against `File.cwd!()` and raises with the
  sibling-clone instruction when the path — or its `examples/` corpus
  directory — is absent.
  """
  @spec repo_path!() :: Path.t()
  def repo_path! do
    configured = Application.get_env(:jido_aph, :aph_repo_path, "../aph")
    path = Path.expand(configured, File.cwd!())

    unless File.dir?(Path.join(path, "examples")) do
      raise """
      the demo cannot find the aph fixture corpus.

      Looked for:   #{Path.join(path, "examples")}
      Configured:   config :jido_aph, aph_repo_path: #{inspect(configured)}
      Resolved from cwd #{File.cwd!()}

      This demo reads its golden envelopes from a SIBLING CLONE of the aph
      repo — it never vendors signed fixtures. Fix by cloning aph next to
      the jido_aph repo:

          git clone https://github.com/squillo/aph.git ../aph

      and run demo tasks/tests from the demo/ directory, whose
      config/config.exs points the key two levels up ("../../aph").
      Absolute paths are safest:

          config :jido_aph, aph_repo_path: "/path/to/aph"
      """
    end

    path
  end

  @doc """
  Reads `examples/<name>` from the sibling aph clone, returning raw bytes.

  Envelope fixtures come back as verbatim JSON text — the form in which an
  APH envelope crosses every boundary. Raises (via `repo_path!/0`) when
  the clone is absent, or `File.Error` when the clone exists but the named
  fixture does not.
  """
  @spec example!(String.t()) :: binary()
  def example!(name) do
    repo_path!() |> Path.join("examples") |> Path.join(name) |> File.read!()
  end
end
