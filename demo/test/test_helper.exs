# The `:deep` tag marks the tests that need the OPTIONAL toolchain: Node >= 20
# plus a built `dist/` in the sibling aph clone's TypeScript interpreter
# (PRD-001 §10 gate 7). They are excluded by default so a fresh clone with no
# Node runs the whole core suite green, and included two ways:
#
#     mix test --include deep
#     APH_DEEP=1 mix test
#
# Included-but-unavailable is a FAILURE, never a silent pass: the deep suite's
# first test asserts `Demo.DeepVerifier.TsSidecar.availability/0` and prints
# that function's setup instructions when it is not `:ok`.
deep? = System.get_env("APH_DEEP") not in [nil, "", "0", "false"]

ExUnit.start(exclude: if(deep?, do: [], else: [:deep]))
