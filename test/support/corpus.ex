defmodule JidoAph.Corpus do
  @moduledoc """
  Test-support loader for the golden fixture corpus in the sibling `aph`
  clone (PRD-001 D7/T6).

  Signed fixtures are never text-edited and never copied into this repo:
  every golden is read from the SHA-pinned sibling checkout at RUNTIME via
  the Application config key `:jido_aph, :aph_repo_path` (default
  `"../aph"`). Resolution happens inside each function call — never at
  compile time — because compile-time `Path.expand` misdepth is the
  documented silent-failure gotcha D7 exists to avoid.

  The relative default is resolved against `File.cwd!()` at the moment of
  the call. That means it is correct when `mix test` runs from the library
  root (where `../aph` is the sibling clone), and WRONG from any nested
  app: callers running from `demo/` (or any other subdirectory project)
  must configure the key accordingly, e.g. in `demo/config/config.exs`:

      config :jido_aph, aph_repo_path: "../../aph"

  or set an absolute path. If the resolved path is not an aph clone, every
  loader function raises loudly with the sibling-clone instruction rather
  than letting tests fail on a confusing `File.Error` deeper in.

  Envelopes cross every boundary as JSON TEXT, so `example!/1` returns raw
  bytes; tests decode only to derive assertions or tamper-variants.
  """

  @doc """
  The resolved aph repo path, validated to look like an aph clone.

  Reads `Application.get_env(:jido_aph, :aph_repo_path, "../aph")` at call
  time and expands it against `File.cwd!()`. Raises with the sibling-clone
  instruction when the path (or its `examples/` corpus directory) is
  absent.
  """
  @spec repo_path!() :: Path.t()
  def repo_path!() do
    configured = Application.get_env(:jido_aph, :aph_repo_path, "../aph")
    path = Path.expand(configured, File.cwd!())

    unless File.dir?(Path.join(path, "examples")) do
      raise """
      jido_aph cannot find the aph fixture corpus.

      Looked for:   #{Path.join(path, "examples")}
      Configured:   config :jido_aph, aph_repo_path: #{inspect(configured)}
      Resolved from cwd #{File.cwd!()}

      This project reads its golden envelopes from a SIBLING CLONE of the
      aph repo — it never vendors signed fixtures. Fix by cloning aph next
      to this repo:

          git clone https://github.com/squillo/aph.git ../aph

      or point the key at your checkout (absolute paths are safest; nested
      apps such as demo/ must NOT rely on the "../aph" default):

          config :jido_aph, aph_repo_path: "/path/to/aph"
      """
    end

    path
  end

  @doc """
  Reads `examples/<name>` from the sibling aph clone, returning raw bytes.

  Envelope fixtures come back as verbatim JSON text — the form in which an
  APH envelope crosses every boundary. Raises (via `repo_path!/0`) when the
  clone is absent, or `File.Error` when the clone exists but the named
  fixture does not.
  """
  @spec example!(String.t()) :: binary()
  def example!(name) do
    repo_path!() |> Path.join("examples") |> Path.join(name) |> File.read!()
  end
end
