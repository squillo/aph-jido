defmodule Demo.RunTranscriptTest do
  # Why this file exists: it is PRD-001 T11's DONE condition — "a golden-output
  # test asserts the banner, the verdict wording, each APH_E* code, and the
  # footer" — and PRD-001 §10 gate 5, which makes the transcript the place the
  # honesty contract is MACHINE-CHECKED rather than merely written down. CI
  # greps `mix demo.run`'s stdout for exactly these strings, so if this file is
  # green the CI grep cannot be silently wrong, and if the demo ever starts
  # narrating something it did not do, this file goes red before a reader is
  # misled.
  #
  # What it pins, beyond the four DONE items:
  #   * that the provenance banner reports the SHA the sibling clone actually
  #     has RIGHT NOW, not a constant baked into the task;
  #   * that the per-leg spec-step enumeration is attributed to the step that
  #     really refused (APH_E012 -> S3, APH_E013 -> S4, byte bound -> S1,
  #     strict parse -> S2), which is the claim PRD-001 §3 step 2 asks for;
  #   * that the bare words "verified" and "signed" appear NOWHERE in the whole
  #     transcript except inside the aph-ex warning that exists to forbid them;
  #   * that `mix demo.run` really writes the transcript to stdout, so the CI
  #     grep has something to grep;
  #   * that the committed docs/transcripts/demo_run.txt still describes the
  #     corpus the demo actually reads today.
  #
  # async: false — the narrative drives the singleton `Demo.Jido` instance and
  # temporarily changes the VM-wide `:default` logger handler's level.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @committed_transcript "../docs/transcripts/demo_run.txt"

  # Build the transcript once. Every assertion below reads the same run, so the
  # file makes exactly one set of claims about exactly one execution — and the
  # seven legs are only paid for once.
  #
  # The run is wrapped in capture_log because jido's AgentServer logs its own
  # [error] line for each refused prepare_signal hook AFTER replying to the
  # caller — i.e. after Demo.Narrative.LogCapture has already put the console
  # back. Those stragglers are real and expected; capturing them keeps them out
  # of the suite's output.
  setup_all do
    {result, _log} = ExUnit.CaptureLog.with_log(fn -> Demo.Narrative.run() end)

    %{transcript: result.transcript, deviations: result.deviations}
  end

  # Why this test exists: it is the DONE condition itself. The four items the
  # card names — banner, verdict wording, each APH_E* code, footer — plus the
  # deviation list, which is the demo's own statement that the story it just
  # told is the run it just made.
  test "the transcript carries the banner, the verdict, both APH_E codes and the footer",
       %{transcript: transcript, deviations: deviations} do
    assert deviations == [],
           "mix demo.run reported deviations:\n" <> Enum.join(deviations, "\n")

    # Banner.
    assert transcript =~ "[1] PROVENANCE"
    assert transcript =~ "aph HEAD"
    assert transcript =~ "examples/principal_signed_envelope.json"
    assert transcript =~ ~r/bytes on disk\s+427/
    assert transcript =~ "bodySize 427"

    # Verdict wording, fixed by PRD-001 §3 step 2 / §8.
    assert transcript =~ Demo.Narrative.verdict()
    assert transcript =~ "notarization-shaped, mode policy satisfied (PrincipalSigned)"

    # Each APH_E* code, with the aph-ex message it leads.
    assert transcript =~ "APH_E012: attestation mode refused"
    assert transcript =~ "APH_E013: proof chain invalid"

    # Footer.
    assert transcript =~ "[10] HONESTY FOOTER"
    assert transcript =~ "N1  No Ed25519 signature was checked"
    assert transcript =~ "N2  No key was discovered or resolved"
    assert transcript =~ "N3  The validity window was never compared against any clock"
    assert transcript =~ "N4  Revocation was never consulted"
    assert transcript =~ "N5  bodySha256 was never recomputed"
    assert transcript =~ "N6  The closed channel and contentClass vocabularies"
    assert transcript =~ "did:web:aph-notary.squillo.com was not contacted"
    assert transcript =~ Demo.Narrative.aph_ex_quote()
  end

  # Why this test exists: the transcript's log lines are the only place a
  # reader sees what an OPERATOR would see, and they are collected through a
  # custom `:logger` handler rather than the console — a rail that can fail
  # silently. It did, once: the handler originally filtered on `meta[:module]`,
  # which Elixir's Logger macros never set (they stamp `:mfa`), so every leg
  # rendered "(this leg emitted no log line of its own)" and the transcript
  # lost the guard's voice entirely while still passing every other assertion
  # here. This pins that regression shut in both directions: the real lines are
  # present, and the empty-leg placeholder appears nowhere.
  test "every leg's real Logger output is captured, not silently dropped",
       %{transcript: transcript} do
    refute transcript =~ "(this leg emitted no log line of its own)"

    assert transcript =~ "log [info] aph_guard: notarization-shaped, mode policy satisfied"
    assert transcript =~ "log [info] deliver_reply: would deliver (no channel adapter)"
    assert transcript =~ "log [warning] aph_guard: refusing signal"
    assert transcript =~ "log [warning] aph_guard: signal"

    # Five refused legs, each logging exactly one refusal line.
    assert length(String.split(transcript, "log [warning] aph_guard: refusing signal")) == 6
  end

  # Why this test exists: a provenance banner that printed a hard-coded SHA
  # would be worse than no banner — it would attribute the run to bytes it
  # never read. This pins that the SHA on the banner is the one `git -C` gives
  # for the clone the demo actually loaded its fixtures from, on this run, and
  # that the fixture identity the banner quotes agrees with the bytes on disk.
  test "the provenance banner reports the clone's real HEAD and the real fixture bytes",
       %{transcript: transcript} do
    repo = Demo.Corpus.repo_path!()
    {sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])
    sha = String.trim(sha)

    assert sha =~ ~r/^[0-9a-f]{40}$/
    assert transcript =~ "aph HEAD              " <> sha

    envelope = Demo.Corpus.example!("principal_signed_envelope.json")
    body = Demo.Corpus.example!("principal_signed_body.txt")

    assert transcript =~ "bytes               #{byte_size(envelope)}"
    assert transcript =~ ~r/bytes on disk\s+#{byte_size(body)}/

    # Decoded only to read the fixture's own claims — never on the trust path.
    communication = get_in(JSON.decode!(envelope), ["credentialSubject", "communication"])
    assert transcript =~ "bodySize #{communication["bodySize"]}"
    assert transcript =~ communication["bodySha256"]

    # And the banner must say, in as many words, that the digest is quoted
    # rather than recomputed: PRD-001 §5 forbids hashing on the BEAM, so a
    # banner implying otherwise would be the overclaim §8 calls poison.
    assert transcript =~ "bodySha256 is NOT recomputed"
  end

  # Why this test exists: PRD-001 §3 step 2 asks the transcript to name, per
  # leg, exactly which spec steps RAN and which did not. That is only a real
  # claim if the attribution follows what actually refused — so this pins the
  # four short-circuit points against the four codes, and pins that the happy
  # path ran all four while the two envelope-less legs ran none.
  test "each leg attributes the refusal to the step that really stopped it",
       %{transcript: transcript} do
    legs = String.split(transcript, "\n[")

    happy = find_leg(legs, "LEG 1 — HAPPY PATH")
    assert happy =~ "S1  §7.1.7.1        RAN"
    assert happy =~ "S2  §8.3 step 1     RAN"
    assert happy =~ "S3  §8.3.1 step 1a  RAN"
    assert happy =~ "S4  §7.1.11         RAN"
    refute happy =~ "NOT REACHED"

    forged = find_leg(legs, "REFUSAL 2/6")
    assert forged =~ "APH_E013"
    assert forged =~ "S3  §8.3.1 step 1a  RAN"
    assert forged =~ "S4  §7.1.11         REFUSED"

    mode_absent = find_leg(legs, "REFUSAL 3/6")
    assert mode_absent =~ "APH_E012"
    assert mode_absent =~ "S2  §8.3 step 1     RAN"
    assert mode_absent =~ "S3  §8.3.1 step 1a  REFUSED"
    assert mode_absent =~ "S4  §7.1.11         NOT REACHED"

    unknown_field = find_leg(legs, "REFUSAL 4/6")
    assert unknown_field =~ "S1  §7.1.7.1        RAN"
    assert unknown_field =~ "S2  §8.3 step 1     REFUSED"
    # The narrative PROSE in this leg says "no APH_E code"; what must be
    # absent is an actual code, i.e. APH_E followed by digits.
    refute unknown_field =~ ~r/APH_E\d/

    oversize = find_leg(legs, "REFUSAL 5/6")
    assert oversize =~ "S1  §7.1.7.1        REFUSED"
    assert oversize =~ "S2  §8.3 step 1     NOT REACHED"
    refute oversize =~ ~r/APH_E\d/

    # The two legs where no envelope ever reached the gate: nothing ran, and
    # neither leg may claim a code.
    for name <- ["REFUSAL 1/6", "ROW 6/6"] do
      leg = find_leg(legs, name)
      assert leg =~ "S1  §7.1.7.1        NOT REACHED"
      assert leg =~ "S4  §7.1.11         NOT REACHED"
      refute leg =~ ~r/APH_E\d/
      # No STEP line may say RAN or REFUSED. The bare words appear elsewhere in
      # these blocks with different meanings — "Demo.Actions.DeliverReply RAN"
      # is true of the pass-through row, and "REFUSED before routing" is the
      # outcome of row 1 — so the refutation is scoped to a step line, which is
      # the only place a spec-step claim can be made.
      refute leg =~ ~r/§[\d.]+\s+RAN/
      refute leg =~ ~r/§[\d.]+\s+REFUSED/
    end

    # Every leg restates what nothing in this repo ever does.
    assert length(String.split(transcript, "never run, this or any leg:")) == 8
  end

  # Why this test exists: PRD-001 §8 makes it a hard rule that the guard never
  # says "verified" or "signed" as bare words, and the demo transcript is the
  # artifact a reader quotes from. The one place those words are allowed is
  # inside aph-ex's own warning — a sentence whose entire purpose is to forbid
  # the claim — so this excises exactly that quote and asserts the rest of the
  # run is clean.
  #
  # It pins "bare word", not "substring": the transcript necessarily contains
  # "PrincipalSigned" (the spec's closed-vocabulary literal),
  # "principal_signed_envelope.json", and "tagged unverified", and all three
  # must pass. Asserting they are present FIRST is what keeps the refutations
  # from passing trivially on an empty string.
  test "the bare words appear nowhere except inside the quoted aph-ex warning",
       %{transcript: transcript} do
    assert transcript =~ "PrincipalSigned"
    assert transcript =~ "principal_signed_envelope.json"
    assert transcript =~ "tagged unverified"

    quote_block = Demo.Narrative.aph_ex_quote()
    assert transcript =~ quote_block
    assert quote_block =~ ~r/\bsigned\b/

    rest = String.replace(transcript, quote_block, "")

    refute rest =~ ~r/\bverified\b/i
    refute rest =~ ~r/\bsigned\b/i
  end

  # Why this test exists: everything above asserts a STRING this module built
  # by calling Demo.Narrative directly. CI greps the task's STDOUT (PRD-001 §10
  # gate 5), which is a different path through the code. This runs the real
  # `mix demo.run` and asserts the exact strings that gate names, so the CI
  # grep and this suite can never disagree about what the task prints.
  test "mix demo.run prints the transcript to stdout" do
    stdout =
      capture_io(fn ->
        ExUnit.CaptureLog.capture_log(fn -> Mix.Task.rerun("demo.run") end)
      end)

    assert stdout =~ "[1] PROVENANCE"
    assert stdout =~ "notarization-shaped, mode policy satisfied"
    assert stdout =~ "APH_E012"
    assert stdout =~ "APH_E013"
    assert stdout =~ "[10] HONESTY FOOTER"
    refute stdout =~ "DEVIATIONS"
  end

  # Why this test exists: the committed transcript is what T14 embeds in the
  # README, and a transcript that quietly describes yesterday's corpus is the
  # exact kind of stale provenance claim the T2 erratum had to file against
  # upstream. It pins that the committed file still carries the same
  # invariants, and that its fixture identity agrees with the bytes the demo
  # reads today — deliberately WITHOUT pinning its SHA, because bumping the
  # sibling pin is a reviewed change and drift is T15's gate, not this one's.
  test "the committed transcript still describes the corpus the demo reads today" do
    path = Path.expand(@committed_transcript, File.cwd!())

    assert File.exists?(path),
           "#{path} is missing; regenerate it with " <>
             "`mix demo.run --out #{@committed_transcript}` from demo/"

    committed = File.read!(path)

    assert committed =~ ~r/aph HEAD\s+[0-9a-f]{40}/
    assert committed =~ "[1] PROVENANCE"
    assert committed =~ Demo.Narrative.verdict()
    assert committed =~ "APH_E012"
    assert committed =~ "APH_E013"
    assert committed =~ "[10] HONESTY FOOTER"
    assert committed =~ Demo.Narrative.aph_ex_quote()

    envelope = Demo.Corpus.example!("principal_signed_envelope.json")
    body = Demo.Corpus.example!("principal_signed_body.txt")
    communication = get_in(JSON.decode!(envelope), ["credentialSubject", "communication"])

    assert committed =~ "bytes               #{byte_size(envelope)}"
    assert committed =~ ~r/bytes on disk\s+#{byte_size(body)}/
    assert committed =~ communication["bodySha256"]
  end

  defp find_leg(legs, name) do
    Enum.find(legs, fn leg -> String.contains?(leg, name) end) ||
      flunk("no leg block containing #{inspect(name)} in the transcript")
  end
end
