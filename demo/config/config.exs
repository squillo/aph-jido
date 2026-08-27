import Config

# PRD-001 D7: golden fixtures are read from the SHA-pinned sibling aph clone
# at RUNTIME via the Application config key `:jido_aph, :aph_repo_path`. The
# library default "../aph" resolves against File.cwd!() — correct from the
# library root, WRONG from this nested app: demo tasks and tests run with
# cwd == demo/, so the clone sits two levels up. Verified empirically (the
# corpus-resolution test in test/demo_happy_path_test.exs asserts the
# resolved path really contains the examples/ corpus).
#
# The key belongs to the :jido_aph app on purpose — one key for the whole
# repo, exactly as the library's own loader moduledoc prescribes for nested
# apps (test/support/corpus.ex).
config :jido_aph, aph_repo_path: "../../aph"

# The demo transcript is an info-level narrative (the guard's admit/refuse
# lines, the would-deliver beat); framework debug noise is not part of the
# story. The guard logs admissions at :info and refusals at :warning, so
# :info is the floor that keeps both.
config :logger, level: :info
