#!/usr/bin/env bash
# Pull upstream xai-org/grok-build, replay the local patches on top, rebuild,
# and point ~/.grok/bin at the result.
#
# The stock binary is left in ~/.grok/downloads, so rollback is just repointing
# the symlinks back at it (printed at the end).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANCH="patch/tolerate-unknown-sse-events"
GROK_HOME="${GROK_HOME:-$HOME/.grok}"
STOCK="grok-0.2.112-linux-x86_64"

cd "$REPO"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty; commit or stash before updating" >&2
  exit 1
fi

echo "==> fetching upstream"
git fetch upstream

# Unconditionally, and before the up-to-date test: otherwise running this
# from `main` while upstream is current would build and install `main` under
# the `-patched-` name, silently replacing the patched binary with a stock one.
git checkout "$BRANCH"

before="$(git rev-parse HEAD)"
if [[ "$(git rev-parse upstream/main)" == "$(git merge-base HEAD upstream/main)" ]]; then
  echo "==> already up to date with upstream/main"
else
  echo "==> rebasing $BRANCH onto upstream/main"
  # Conflicts, if any, land in the two patched files. Resolve them, run
  # `git rebase --continue`, then re-run this script.
  git rebase upstream/main
fi

echo "==> testing the patches"
test_log="$(mktemp)"
trap 'rm -f "$test_log"' EXIT
cargo test -p xai-grok-sampler --lib -- \
  unknown_top_level nested_unknown web_search_call xai_hosted deserialize_response_event \
  2>&1 | tee "$test_log"

# `cargo test` exits 0 when a filter matches no tests, so a green run proves
# nothing on its own. Confirm each patch test actually reported ok.
for t in unknown_top_level_events_are_detected \
         nested_unknown_variant_is_not_treated_as_unknown_event \
         in_progress_web_search_call_without_action_parses \
         xai_hosted_tools_only_ship_to_xai_endpoints; do
  if ! grep -q "test client::tests::${t} \.\.\. ok" "$test_log"; then
    echo "error: patch test '$t' did not run — are the patches present?" >&2
    exit 1
  fi
done

echo "==> building (a few minutes)"
cargo build -p xai-grok-pager-bin --release

version="$(grep -m1 '^version' crates/codegen/xai-grok-version/Cargo.toml | cut -d'"' -f2)"
artifact="grok-${version}-patched-linux-x86_64"

echo "==> installing $artifact"
cp target/release/xai-grok-pager "$GROK_HOME/downloads/$artifact"
chmod +x "$GROK_HOME/downloads/$artifact"
ln -sfn "../downloads/$artifact" "$GROK_HOME/bin/grok"
ln -sfn "../downloads/$artifact" "$GROK_HOME/bin/agent"

echo "==> done: $("$GROK_HOME/bin/grok" --version)"
[[ "$before" != "$(git rev-parse HEAD)" ]] && echo "    (was $before)"
echo "    rollback: ln -sfn ../downloads/$STOCK $GROK_HOME/bin/grok"
