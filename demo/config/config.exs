import Config

# PRD-001 D7: golden fixtures are read from a SHA-pinned aph checkout at
# RUNTIME, never vendored. This app deliberately sets NO `:aph_repo_path`.
#
# It used to set "../../aph", because the corpus came from a sibling clone and
# this app sits one level deeper than the library, so the relative path had to
# grow a level. The `:aph` dependency now arrives as git + `subdir:`, which
# clones the WHOLE aph repository into demo/deps/aph — so Demo.Corpus locates
# it through `Mix.Project.deps_paths()` instead, which is correct in both apps
# without either one knowing how deep it sits.
#
# Setting the key here would override that and pin the demo to one layout
# again. It stays available for anyone who wants it (an absolute path is the
# safe spelling), and `APH_PATH` moves the dependency and the corpus together.

# The demo transcript is an info-level narrative (the guard's admit/refuse
# lines, the would-deliver beat); framework debug noise is not part of the
# story. The guard logs admissions at :info and refusals at :warning, so
# :info is the floor that keeps both.
config :logger, level: :info
