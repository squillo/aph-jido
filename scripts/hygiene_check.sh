#!/usr/bin/env bash
#
# hygiene_check.sh — the naming gate for jido_aph (PRD-001 T14, acceptance
# gate 8). CI runs this unchanged (PRD-001 T15).
#
# Two invariants, over every git-TRACKED file in the repository:
#
#   1. The retired domain appears NOWHERE. No allowlist, no exceptions.
#      Domain canon for this project is squillo.com; a stray retired-domain
#      string in shipped text is a claim about an address that is not ours.
#
#   2. The fixture notary DID appears ONLY where it is quoted and explained.
#      `did:web:notary.<canon>` is the verificationMethod of the aph repo's
#      golden envelope. It is a FIXTURE IDENTIFIER: never resolved, never
#      fetched, never contacted by anything in this repository. It rides
#      inside the fixture bytes, it is the key of the one out-of-band entry
#      in the deep verifier's keys map, and it is named in the prose that
#      explains that sourcing. Anywhere else, it would read as a live
#      service — which is exactly the overclaim PRD-001 §8 forbids.
#
# Both forbidden strings are ASSEMBLED AT RUNTIME from parts, so this
# script's own source contains neither literal. That is deliberate: it means
# the script does not appear in its own allowlist. A hygiene gate that
# allowlists itself can hide anything, and proves nothing.
#
# Usage:
#   scripts/hygiene_check.sh                  # check this repository
#   scripts/hygiene_check.sh --self-test      # prove the checks really fail
#   scripts/hygiene_check.sh --root <dir>     # check some other checkout
#
# Exit status: 0 clean, 1 violations found, 2 usage/environment error.

set -euo pipefail

# ---------------------------------------------------------------------------
# The two patterns, assembled rather than spelled.
# ---------------------------------------------------------------------------

canon_domain="squillo.com"

retired_tld="io"
retired_domain="squillo.${retired_tld}"

fixture_notary_did="did:web:notary.${canon_domain}"

# ---------------------------------------------------------------------------
# The allowlist for invariant 2, as an explicit path list.
#
# Each entry is "<repo-relative path>|<why this occurrence is legitimate>".
# The reason is not decoration: it is the review record. Adding a path here
# is a claim that the identifier is quoted and explained at that path, and
# the reviewer of that change is asserting it.
#
# NOT on this list, deliberately: everything under lib/. The library proper
# does not mention the fixture notary at all, and must not start.
# ---------------------------------------------------------------------------

notary_allowlist=(
  "README.md|the key-sourcing section, plus the deep transcript embedded as Appendix B"
  "docs/transcripts/demo_deep_verify.txt|committed transcript: the deep leg's own stdout, which names the identifier to say it was not contacted"
  "demo/priv/node/verify.mjs|the keys map — the one place key material is bound to this identifier, imported from the aph testkit's RFC 8032 vector"
  "demo/lib/demo/deep_verifier/ts_sidecar.ex|the sidecar's key-sourcing report and the moduledoc explaining the out-of-band supply"
  "demo/lib/mix/tasks/demo.deep_verify.ex|the narration that renders the transcript's key-sourcing section"
  "demo/test/demo_deep_verifier_test.exs|pins the key-sourcing story: supplied out of band, zero fetched"
  "demo/test/demo_deep_verify_transcript_test.exs|pins the transcript's FIXTURE IDENTIFIER sentence"
  "PRDs/PRD-001-Jido-APH-Guard.md|the design record that specifies the out-of-band supply and this very gate"
)

# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------

# Tracked files only. That is the repository as CI checks it out, and it
# keeps _build/, deps/ and node_modules/ out without an exclude list that
# would rot. Binary files are skipped by grep -I.
scan() {
  local root="$1" pattern="$2"
  (
    cd "$root"
    git ls-files -z | xargs -0 grep -I -n -F -e "$pattern" -- /dev/null
  ) || true
}

path_of() { printf '%s' "${1%%:*}"; }

allowlist_reason() {
  local path="$1" entry
  for entry in "${notary_allowlist[@]}"; do
    if [ "${entry%%|*}" = "$path" ]; then
      printf '%s' "${entry#*|}"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Check 1 — the retired domain, anywhere, no allowlist.
# ---------------------------------------------------------------------------

check_retired_domain() {
  local root="$1" hits
  hits="$(scan "$root" "$retired_domain")"

  if [ -z "$hits" ]; then
    printf '  OK   retired domain: absent from every tracked file\n'
    return 0
  fi

  printf '  FAIL retired domain found (there is no allowlist for this):\n'
  printf '%s\n' "$hits" | sed 's/^/         /'
  printf '\n       Domain canon for this project is %s. Rewrite the\n' "$canon_domain"
  printf '       occurrence; do not add an exception, because there is no\n'
  printf '       mechanism here to add one.\n'
  return 1
}

# ---------------------------------------------------------------------------
# Check 2 — the fixture notary DID, allowlisted by path.
# ---------------------------------------------------------------------------

check_fixture_notary_did() {
  local root="$1" hits line path reason rc=0
  local -a violations=()
  local -a allowed_paths=()

  hits="$(scan "$root" "$fixture_notary_did")"

  if [ -n "$hits" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      path="$(path_of "$line")"
      if allowlist_reason "$path" >/dev/null; then
        case " ${allowed_paths[*]-} " in
          *" $path "*) ;;
          *) allowed_paths+=("$path") ;;
        esac
      else
        violations+=("$line")
      fi
    done <<< "$hits"
  fi

  if [ "${#violations[@]}" -eq 0 ]; then
    printf '  OK   fixture notary DID: %d allowlisted path(s), 0 elsewhere\n' \
      "${#allowed_paths[@]}"
    for path in ${allowed_paths[@]+"${allowed_paths[@]}"}; do
      reason="$(allowlist_reason "$path")"
      printf '         %s\n           %s\n' "$path" "$reason"
    done
  else
    printf '  FAIL fixture notary DID outside the allowlist:\n'
    printf '%s\n' "${violations[@]}" | sed 's/^/         /'
    printf '\n       That identifier is a FIXTURE, never a live service. It\n'
    printf '       belongs only where it is quoted AND explained. If this new\n'
    printf '       occurrence explains itself, add its path to\n'
    printf '       notary_allowlist in this script with the reason — that\n'
    printf '       entry is the review record.\n'
    rc=1
  fi

  return "$rc"
}

# ---------------------------------------------------------------------------
# Running the gate
# ---------------------------------------------------------------------------

run_checks() {
  local root="$1" rc=0
  check_retired_domain "$root" || rc=1
  check_fixture_notary_did "$root" || rc=1
  return "$rc"
}

# ---------------------------------------------------------------------------
# Self-test — a gate never observed to fail is not evidence of anything.
#
# Builds a throwaway git repository, plants one violation of each invariant
# plus one allowlisted occurrence that MUST pass, and asserts the checker's
# verdict on each. The planted strings are built from the same assembled
# variables, so this file still contains neither literal.
# ---------------------------------------------------------------------------

self_test() {
  local tmp out rc=0 failures=0

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  git -C "$tmp" init -q
  mkdir -p "$tmp/lib" "$tmp/docs/transcripts"

  printf 'clean file, nothing forbidden here\n' > "$tmp/clean.md"
  printf 'the key is %s#key-1, explained here\n' "$fixture_notary_did" \
    > "$tmp/README.md"
  git -C "$tmp" add -A
  printf '  case 1  clean repo + allowlisted occurrence ... '
  if out="$(run_checks "$tmp" 2>&1)"; then
    printf 'pass\n'
  else
    printf 'FAIL (expected clean, got violations)\n%s\n' "$out"
    failures=$((failures + 1))
  fi

  printf 'see http://docs.%s/x for details\n' "$retired_domain" \
    > "$tmp/docs/stale.md"
  git -C "$tmp" add -A
  printf '  case 2  retired domain planted ............... '
  if out="$(run_checks "$tmp" 2>&1)"; then
    printf 'FAIL (violation not caught)\n'
    failures=$((failures + 1))
  elif printf '%s' "$out" | grep -q 'docs/stale.md'; then
    printf 'caught\n'
  else
    printf 'FAIL (failed, but did not name docs/stale.md)\n%s\n' "$out"
    failures=$((failures + 1))
  fi
  rm "$tmp/docs/stale.md"

  printf 'resolve %s at boot\n' "$fixture_notary_did" > "$tmp/lib/leak.ex"
  git -C "$tmp" add -A
  printf '  case 3  fixture DID outside allowlist ........ '
  if out="$(run_checks "$tmp" 2>&1)"; then
    printf 'FAIL (violation not caught)\n'
    failures=$((failures + 1))
  elif printf '%s' "$out" | grep -q 'lib/leak.ex'; then
    printf 'caught\n'
  else
    printf 'FAIL (failed, but did not name lib/leak.ex)\n%s\n' "$out"
    failures=$((failures + 1))
  fi

  printf '  case 4  allowlisted file still passes ....... '
  if printf '%s' "$out" | grep -q 'README.md:1'; then
    printf 'FAIL (allowlisted README.md reported as a violation)\n'
    failures=$((failures + 1))
  else
    printf 'pass\n'
  fi

  rm "$tmp/lib/leak.ex"
  git -C "$tmp" add -A
  printf '  case 5  violations removed, gate clears ..... '
  if run_checks "$tmp" >/dev/null 2>&1; then
    printf 'pass\n'
  else
    printf 'FAIL (repo is clean but gate still fails)\n'
    failures=$((failures + 1))
  fi

  printf '\n'
  if [ "$failures" -eq 0 ]; then
    printf 'self-test: 5/5 cases behaved as specified.\n'
  else
    printf 'self-test: %d case(s) FAILED — the gate is not trustworthy.\n' \
      "$failures"
    rc=1
  fi

  return "$rc"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  local mode="check" root=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --self-test) mode="self-test"; shift ;;
      --root) root="${2-}"; [ -n "$root" ] || { printf 'error: --root needs a path\n' >&2; exit 2; }; shift 2 ;;
      -h|--help) sed -n '2,30p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
      *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
  done

  command -v git >/dev/null 2>&1 || { printf 'error: git is required\n' >&2; exit 2; }

  if [ "$mode" = "self-test" ]; then
    printf 'hygiene_check.sh --self-test\n\n'
    self_test
    exit $?
  fi

  if [ -z "$root" ]; then
    root="$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)" || {
      printf 'error: not inside a git repository\n' >&2
      exit 2
    }
  fi

  printf 'hygiene_check.sh — %s\n\n' "$root"
  if run_checks "$root"; then
    printf '\nclean.\n'
    exit 0
  else
    printf '\nhygiene gate FAILED.\n'
    exit 1
  fi
}

main "$@"
