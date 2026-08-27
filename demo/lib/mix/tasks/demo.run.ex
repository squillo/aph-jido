defmodule Mix.Tasks.Demo.Run do
  @shortdoc "Runs the APH guard demo and prints the narrated transcript"

  @moduledoc """
  Runs the whole `jido_aph` guard demo and prints a narrated transcript
  (PRD-001 §3, task T11).

      mix demo.run
      mix demo.run --out ../docs/transcripts/demo_run.txt

  ## What it prints, in order

  1. a **provenance banner** — the sibling aph clone's HEAD SHA, read from
     the clone with `git -C` at runtime, its worktree cleanliness, and the
     golden fixture's identity down to the 427-byte body;
  2. the **gate vocabulary** — the four spec steps `JidoAph.Guard` runs
     (§7.1.7.1, §8.3 step 1, §8.3.1 step 1a, §7.1.11) and the six things
     nothing in this repo ever runs;
  3. the **happy path** — Scribe presents the golden envelope, Gateway
     admits it, `Demo.Actions.DeliverReply` logs its would-deliver beat;
  4. the **full six-row refusal matrix**, every negative derived in memory
     on this run and never written to disk;
  5. per leg, which of the four steps RAN, which one REFUSED, and which
     were NEVER REACHED — attributed from the guard's own message, not from
     a script;
  6. the **honesty footer** — the not-checked list, and aph-ex's own warning
     that a structure pass says nothing about any signature.

  ## Node is not required

  Nothing here shells out except `git`, and nothing reaches the network.
  Cryptographic depth is the separate, optional `mix demo.deep_verify` leg.

  ## Exit status

  Zero when every leg did what the transcript says it did. Non-zero, with
  the deviations printed after the transcript, when it did not: this task is
  a gate as well as a story, which is why CI can grep its stdout (PRD-001
  §10 gate 5).

  ## Options

    * `--out PATH` — additionally write the transcript (and only the
      transcript) to `PATH`, creating parent directories as needed. This is
      how `docs/transcripts/demo_run.txt` is regenerated; run it from
      `demo/`, so the repo-root path is `../docs/transcripts/demo_run.txt`.

  ## Prerequisites

  A sibling clone of the aph repo, resolved at runtime through
  `config :jido_aph, aph_repo_path: "../../aph"` (PRD-001 D7). Without it,
  `Demo.Corpus` raises with the clone command spelled out.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [out: :string])

    %{transcript: transcript, deviations: deviations} = Demo.Narrative.run()

    IO.write(transcript)

    case Keyword.fetch(opts, :out) do
      {:ok, path} -> write_out(path, transcript)
      :error -> :ok
    end

    report(deviations)
  end

  defp write_out(path, transcript) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, transcript)
    IO.puts("\ntranscript written to #{path}")
  end

  defp report([]), do: :ok

  defp report(deviations) do
    IO.puts("\n" <> String.duplicate("!", 78))
    IO.puts("DEVIATIONS — the demo did not do what the transcript above narrates:")
    IO.puts(String.duplicate("!", 78))
    Enum.each(deviations, fn deviation -> IO.puts("  - " <> deviation) end)

    Mix.raise(
      "mix demo.run found #{length(deviations)} deviation(s); the transcript is not " <>
        "a truthful record of this run"
    )
  end
end
