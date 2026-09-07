#!/usr/bin/env bash
# Pin both guest projects to a specific SPEL commit.
#
# Usage: ./scripts/pin-versions.sh <spel-ref>
#
# The guests are always compiled against the LEZ revision that SPEL itself
# pins, and that is deliberate — see "Why the LEZ version is not an argument".
#
# ── Why this is not just a sed ────────────────────────────────────────────
#
# Cargo unifies git dependencies by their *source string*, not by the commit
# they resolve to. `tag = "v0.2.4"` and `rev = "47eba25…"` name the same commit
# but are two different sources, so rewriting the guest's selector to a rev
# while `spel-framework` still says `tag = "v0.2.4"` puts **two copies of
# lee_core** in the graph. The guest then fails to compile with
#
#     expected `lee_core::account::data::Data`, found `lee_core::account::Data`
#     note: two different versions of crate `lee_core` are being used
#
# fifteen minutes into a Docker build. So the guest's LEZ selector is copied
# *verbatim* from spel-framework, and the resulting lockfile is asserted to
# contain exactly one `lee_core` — turning that failure into an immediate one.
#
# ── Why the LEZ version is not an argument ────────────────────────────────
#
# It cannot be overridden here, and it does not need to be. `[patch]` is the
# only way to force one LEZ across both the guest and spel-framework, and Cargo
# rejects a patch whose replacement is the same git source — including
# `.git`-suffix variants, which it canonicalizes. Nothing short of a fork URL
# or a vendored path copy gets around that.
#
# It does not need to be, because the version a guest is *compiled* against and
# the version of the *chain it runs on* are separate. `scripts/e2e-test.sh`
# takes its sequencer, wallet and configs from whatever LEZ checkout it is
# pointed at, so running guests built on SPEL's pinned LEZ against a newer node
# is a supported (and more interesting) configuration: it asks whether programs
# built with today's SPEL still work on tomorrow's chain, which is a wire and
# validation-rule question that no amount of `cargo check` can answer.
#
# To compile against a different LEZ, test a SPEL ref that pins it — SPEL's own
# `lez-compat` workflow opens `lez-bump/<sha>` branches that do exactly that.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEL_REF="${1:?usage: pin-versions.sh <spel-ref>}"

SPEL_GIT="https://github.com/logos-co/spel.git"
LEZ_GIT="https://github.com/logos-blockchain/logos-execution-zone.git"

SPEL_SHA=$("$REPO_ROOT/scripts/resolve-ref.sh" "$SPEL_GIT" "$SPEL_REF")

SPEL_MANIFEST=$(curl -fsSL "https://raw.githubusercontent.com/logos-co/spel/${SPEL_SHA}/spel-framework/Cargo.toml")
SPEL_LEZ_SELECTOR=$(grep 'nssa_core' <<<"$SPEL_MANIFEST" | grep -oE '(tag|rev|branch) = "[^"]*"' | head -1)
[ -n "$SPEL_LEZ_SELECTOR" ] || { echo "could not read SPEL's LEZ pin at $SPEL_SHA" >&2; exit 1; }
SPEL_LEZ_REF=$(cut -d'"' -f2 <<<"$SPEL_LEZ_SELECTOR")
SPEL_LEZ_SHA=$("$REPO_ROOT/scripts/resolve-ref.sh" "$LEZ_GIT" "$SPEL_LEZ_REF")

echo "SPEL $SPEL_REF -> $SPEL_SHA"
echo "LEZ  (from SPEL) $SPEL_LEZ_REF -> $SPEL_LEZ_SHA"
echo

for project in ledger vault; do
    guest="$REPO_ROOT/$project/methods/guest"
    [ -f "$guest/Cargo.toml" ] || { echo "missing $guest/Cargo.toml" >&2; exit 1; }

    python3 - "$guest/Cargo.toml" "$SPEL_SHA" "$SPEL_LEZ_SELECTOR" <<'PY'
import re, sys
manifest, spel_sha, lez_selector = sys.argv[1:4]
src = open(manifest).read()

def repin(text, dep, selector):
    pat = re.compile(rf'^(\s*{re.escape(dep)}\s*=\s*\{{[^}}\n]*?)\b(?:branch|tag|rev)\s*=\s*"[^"]*"', re.M)
    out, n = pat.subn(lambda m: m.group(1) + selector, text)
    if n == 0:
        sys.exit(f"{manifest}: no git selector found for '{dep}'")
    return out

src = repin(src, 'spel-framework', f'rev = "{spel_sha}"')
# Verbatim, so the guest and spel-framework name one source.
src = repin(src, 'nssa_core', lez_selector)
open(manifest, 'w').write(src)
PY

    # A *targeted* update, never `cargo generate-lockfile`. Regenerating
    # re-resolves the whole graph to the newest crates.io versions, which pulls
    # in crates that outrun the risc0 toolchain's rustc:
    #
    #     error: rustc 1.88.0-dev is not supported by the following packages:
    #       enum-ordinalize@4.4.2 requires rustc 1.89
    #
    # It also means a run would be testing unrelated dependency drift rather
    # than the SPEL change under test. So re-resolve only what actually moved
    # and fail loudly if that is not possible.
    (
        cd "$guest"
        if [ ! -f Cargo.lock ]; then
            echo "  $project: no lockfile, generating one" >&2
            cargo generate-lockfile --quiet
        elif ! cargo update -p spel-framework -p lee_core --quiet; then
            echo "ERROR: could not re-resolve spel-framework/lee_core in $project." >&2
            echo "       Refusing to regenerate the whole lockfile — that pulls in" >&2
            echo "       crates newer than the risc0 toolchain's rustc supports." >&2
            exit 1
        fi
    )

    # The check that matters: one lee_core, or the guest will not compile.
    sources=$(grep -A3 'name = "lee_core"' "$guest/Cargo.lock" | grep -c '^source = ' || true)
    if [ "$sources" != "1" ]; then
        echo "ERROR: $project resolved $sources copies of lee_core — the guest cannot compile." >&2
        grep -A3 'name = "lee_core"' "$guest/Cargo.lock" | grep '^source = ' >&2
        exit 1
    fi
    echo "  $project: ok (1 lee_core)"
done

echo
grep -hE '^(spel-framework|nssa_core)' "$REPO_ROOT"/*/methods/guest/Cargo.toml | sort -u
# Consumed by CI to key the guest cache and to report what was built.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "guest_lez_sha=$SPEL_LEZ_SHA" >> "$GITHUB_OUTPUT"
fi
