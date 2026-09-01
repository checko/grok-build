# Local patches: `patch/tolerate-unknown-sse-events`

This branch carries a small set of patches on top of upstream `xai-org/grok-build`
so that `grok` works against an **OpenAI-compatible passthrough gateway** using the
`responses` API backend, with hosted web search enabled.

Stock `grok` fails against such a gateway in three separate ways. Each patch fixes
one of them. All three are confined to a single file,
`crates/codegen/xai-grok-sampler/src/client.rs`, which is deliberate: keeping the
blast radius to one file keeps rebases cheap. That file churns upstream — the
0.2.112 → 0.2.120 sync rewrote 490 of its lines — and every sync since has
conflicted: 0.2.120 → 1.0.5 on one comment, 1.0.5 → 1.0.13 on four hunks. Budget
for a conflict every cycle now, not every few.

## Branch layout

```
patch/tolerate-unknown-sse-events   ← the patches live here (this branch)
main                                ← untouched mirror of upstream/main
```

`main` is never patched. It is kept byte-identical to `upstream/main` so the
patch branch can always be replayed onto a fresh upstream with a plain rebase.

The branch additionally carries one build-tooling commit, `062af90`, which makes
`cargo build` work on Windows. It touches
`crates/build/xai-proto-build/src/lib.rs` and does not affect generated code or
the Linux build — see [WINDOWS-BUILD.md](WINDOWS-BUILD.md). A rebase therefore
has two files that could conflict, not one.

Remotes:

| remote | URL |
|---|---|
| `origin` | `git@github.com:checko/grok-build.git` (the fork) |
| `upstream` | `https://github.com/xai-org/grok-build.git` |

## What the patches do

| commit | fix |
|---|---|
| `2a789c0` | Skip unknown Responses stream events instead of failing the turn |
| `5a87d5b` | Backfill `action` on in-progress `web_search_call` items |
| `dcda06b` | Send `x_search` only to xAI-operated endpoints |
| `98d16a5` | Add `update-and-install.sh` |

Rebasing rewrites those SHAs every time, so they are indicative only — read the
live stack with `git log --oneline upstream/main..HEAD`. The table above is as
of the rebase onto upstream `bb7f39d5` (v1.0.13).

**None of the three has been adopted upstream as of v1.0.13.** Verified there:
`deserialize_response_event` still strips only unparseable `/response/tools`
entries and returns `SamplingError::Serialization` on everything else
(`client.rs:240`); `retry.rs:209` still classifies that error as fatal on the
first attempt; and nothing backfills `action`. Expect to keep carrying these.

Note 1.0.13 added automatic retry for transient inference failures and for
length-truncated responses. That is adjacent to patch 1 but does not replace it:
a serialization error is still classified fatal on the first attempt, so an
unknown SSE event still kills the turn without the patch.

**1. Unknown SSE events.** The `async-openai` fork models Responses-API stream
events as a closed `enum`. A gateway that emits any event type outside that enum
(`keepalive`, `response.metadata`, …) triggers a non-retryable serialization
error that kills the turn mid-response. The patch detects the case where the
*top-level* `type` field is the unknown variant and skips that event, while still
failing loudly on unknown variants nested deeper (which would indicate a real
schema mismatch).

**2. Missing `action` field.** A `web_search_call` item carries an `action` field
when the search completes (`.done`), but not when it starts (`.added`). Strict
deserialization rejects the in-progress item with `missing field 'action'`,
aborting the turn as soon as a search begins. The patch backfills a placeholder
`action` on items that lack one.

**3. `x_search` sent to non-xAI endpoints.** `grok` injects xAI's proprietary
`x_search` hosted tool alongside `web_search`. A non-xAI endpoint rejects the
whole request with `HTTP 400 Unsupported tool type: x_search` — and because that
fails request validation it kills every turn, not just searches. The patch
filters xAI-only hosted tools by the endpoint host, so they ship to `*.x.ai` and
`*.grok.com` but not to third-party gateways. Nothing needs configuring — the
host is read from `base_url`.

> **Read this before touching patch 3.** The filter must stay **per tool**.
> Through v0.2.120 `web_search` shipped as a native `rs::Tool::WebSearch` and
> only `x_search` rode the raw-JSON `extra_tool_entries` channel, so gating the
> whole call was equivalent. As of v1.0.5 both ride that channel — `web_search`
> moved because async-openai's typed `WebSearchToolFilters` cannot express
> `excluded_domains` (`conversation/responses.rs:345`) — so skipping the
> call now drops hosted web search along with `x_search`, silently. The endpoint
> filter therefore lives in `extra_tool_entries_for_endpoint`, which drops
> entries by `HostedTool::wire_name()` and is applied at **both** call sites:
> `conversation_stream_responses` and the non-streaming `conversation_responses`
> that upstream added in 1.0.5.
>
> `non_xai_endpoints_keep_web_search_and_drop_x_search` is the regression test
> for exactly this. The older `xai_hosted_tools_only_ship_to_xai_endpoints`
> covers only the host predicate and keeps passing when the filter is wrong, so
> it is not a substitute.

Five unit tests cover the patches. Run them with:

```bash
cargo test -p xai-grok-sampler --lib -- \
  unknown_top_level nested_unknown web_search_call xai_hosted non_xai_endpoints
```

Omitting `non_xai_endpoints` leaves patch 3's real regression test unrun, which
is the mistake the filter above exists to catch.

## Installing on another machine

The target machine is assumed to already have stock `grok` installed, so that
`~/.grok/bin/` and `~/.grok/downloads/` exist.

Both options below are Linux-only. **On Windows, see
[WINDOWS-BUILD.md](WINDOWS-BUILD.md)** — the toolchain setup differs, three
build-level problems have to be worked around, and `~/.grok/bin` holds real file
copies rather than symlinks.

### Option A — copy the built binary (fast)

The build is a normal dynamically-linked ELF needing only `libz`, `libgcc_s`,
`libm`, and `libc`. Two hard requirements:

- **x86_64** — an ARM machine must build from source (Option B)
- **glibc ≥ 2.39** — the highest versioned symbol referenced. Ubuntu 24.04 is
  2.39; Ubuntu 22.04 (2.35) and Debian 12 (2.36) are too old and will fail to
  start. Check with `ldd --version`.

```bash
# from the machine that has the build (~197 MB)
scp ~/.grok/downloads/grok-<version>-patched-linux-x86_64 OTHER:~/.grok/downloads/

# on the target machine
chmod +x ~/.grok/downloads/grok-<version>-patched-linux-x86_64
ln -sfn ../downloads/grok-<version>-patched-linux-x86_64 ~/.grok/bin/grok
ln -sfn ../downloads/grok-<version>-patched-linux-x86_64 ~/.grok/bin/agent
```

Repoint **both** symlinks — `agent` is what subagent spawns exec.

### Option B — build from source (any arch, stays current)

```bash
# The toolchain is pinned in rust-toolchain.toml (1.94.0 as of v1.0.13) and
# rustup installs and selects it per-directory on the first `cargo` command.
# Never run `rustup update` for this — the pin is an exact version and the
# `stable` channel is unrelated.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

git clone git@github.com:checko/grok-build.git grok-build-src
cd grok-build-src
git remote add upstream https://github.com/xai-org/grok-build.git
git fetch upstream
git checkout patch/tolerate-unknown-sse-events

# required — rebases abort with "Committer identity unknown" without it
git config user.name  "checko"
git config user.email "checko@gmail.com"

./update-and-install.sh
```

Budget **26 GB** of disk for `target/` and roughly 3–4 minutes for a warm
release build. When upstream bumps `rust-toolchain.toml`, every fingerprint in
`target/` is invalidated and the build is cold — measured at **6m 03s** for the
1.92.0 → 1.94.0 bump. Cargo does not garbage-collect the superseded artifacts,
so `target/` grows across a toolchain bump; `cargo clean` first if disk is
tight.

### Required configuration

In `~/.grok/config.toml` on every machine:

```toml
[model.<your-model-id>]
base_url = "http://<your-passthrough>/v1"
api_backend = "responses"          # the patches only matter on this backend
supports_backend_search = true

[cli]
auto_update = false                # REQUIRED — see below
```

`auto_update = false` is not optional. Without it the updater downloads a stock
release and silently overwrites the `~/.grok/bin/grok` symlink on a later launch
(short-circuits at `crates/codegen/xai-grok-update/src/auto_update.rs:593` in
`check_update_background` and `:682` in `run_update_if_available`; the setting
defaults to true when unset — `auto_update.rs:687`).

## Checking for updates

`auto_update = false` disables the *startup* check as well as the download, so
`grok` will never tell you a new version exists. Check on demand instead:

```bash
grok update --check
# Grok Build - v1.0.13 (latest: 1.0.13)                        ← current
# A new version of Grok Build is available: 1.0.13 -> 1.0.14   ← rebuild
```

This works despite the pin because `check_update_status`
(`crates/codegen/xai-grok-update/src/auto_update.rs:224`) never consults
`auto_update`. Add `--json` for scripting.

> **Never run plain `grok update`.** With `installer = "internal"` it will
> overwrite the patched binary with a stock build. `--check` is read-only.

xAI publishes release binaries **before** pushing the matching source to the
public repo — observed lag has been ~13 hours. So `grok update --check` can
announce a version that is not yet buildable. To confirm the source has landed:

```bash
git fetch -q upstream
git rev-list --count HEAD..upstream/main    # 0 = nothing new to build
```

`grok update --check` says a release exists; `git rev-list` says it is
buildable. If the first says yes and the second says 0, wait and re-check.

Nothing is scheduled — no cron entry, no systemd timer. Both checks are manual.

### The `[alpha]` / `[stable]` / no-label suffix on `--version`

Whatever `--version` prints after the SHA is cosmetic and says nothing about
which channel the build came from. `channel_label()`
(`crates/codegen/xai-grok-update/src/version.rs:551`) compares the compiled
version against the `stable_version` cached in `~/.grok/version.json`: ahead of
it reads `[alpha]`, equal reads `[stable]`, and **no cached pointer at all reads
as the empty string** (`version.rs:557`).

All three show up in practice. A self-built binary sitting on a stale cache
written by an older stock install reads `[alpha]`. After a `grok update --check`
the cache is rewritten, and if the fetch of the stable pointer fails or is
skipped, `stable_version` lands as `null` and the label disappears entirely —
`grok 1.0.13 (<tip>)` with no suffix, which is what a current build normally
looks like here.

Note `auto_update = false` does **not** freeze this cache: `check_update_status`
never consults that setting, so any `grok update --check` refreshes it. Nothing
about any of this affects behaviour.

## Updating

```bash
cd /path/to/grok-build-src
./update-and-install.sh
```

The script:

1. refuses to run on a dirty working tree
2. `git fetch upstream`
3. checks out this branch (unconditionally — see below)
4. rebases it onto `upstream/main` (skipped when already current)
5. runs the patch tests, then asserts by name that all five actually reported
   `ok` — `cargo test` exits 0 when a filter matches nothing, so the exit status
   alone would not prove the patches are present
6. `cargo build -p xai-grok-pager-bin --release`
7. copies to `~/.grok/downloads/grok-<version>-patched-linux-x86_64` and repoints
   `bin/grok` and `bin/agent`
8. prints the new version and the rollback command

Step 3 used to sit inside the else-branch of the up-to-date test, so running the
script from `main` while upstream was current would build `main` and install it
under the `-patched-` name — quietly replacing the patched binary with a stock
one. Both that and the silently-vacuous test run are fixed; the checkout is now
unconditional and step 5 fails loudly if a patch test is missing.

It never pushes. To publish the rebased branch afterwards, note that rebasing
rewrites the commit SHAs, so a plain push is rejected:

```bash
git push --force-with-lease origin patch/tolerate-unknown-sse-events
```

### If a rebase conflicts

Conflicts can appear in `client.rs` or, on Windows, `xai-proto-build/src/lib.rs`.
Resolve, then:

```bash
git rebase --continue
./update-and-install.sh
```

To bail out entirely: `git rebase --abort`.

Resolving a conflict is not enough on its own when upstream has moved the code
the patch depends on. The v1.0.5 rebase conflicted on one comment, and taking
the patch side verbatim would have compiled, passed the old tests, and silently
disabled hosted web search — see the warning under patch 3. When a conflict
lands in `client.rs`, re-read what the surrounding upstream code now does before
deciding the resolution is mechanical.

**The 1.0.5 → 1.0.13 rebase.** Four conflict hunks, all in `client.rs`, all
caused by upstream reflowing doc comments from multi-line blocks to single long
lines — not by any logic change. Two in patch 1 (the `deserialize_response_event`
doc, and the same doc restated above a test), two in patch 3 (the comment above
each `extra_tool_entries` call site). Resolution in both patches: keep upstream's
reflowed prose, re-apply our code. Patch 2 replayed clean.

That reflow is why the sync's diffstat reads 2,525 files and +235k/-174k —
roughly 120k of the 400k changed lines are `///` comments. Do not read the size
as a signal of risk; check what actually moved.

The premise of patch 3 was re-verified rather than assumed: `extra_tool_entries`
(`conversation/responses.rs:348`) still emits both `web_search` and `x_search`
onto the raw-JSON channel, and `HostedTool::wire_name()` (`conversation.rs:496`)
is unchanged with no new variants. Do this check on every rebase — if a future
sync moves `web_search` back to a typed `rs::Tool`, the per-tool filter needs
revisiting.

## Rollback

Stock binaries are never deleted, so rollback is just repointing the symlink:

```bash
ls ~/.grok/downloads/                                   # find the stock build
ln -sfn ../downloads/grok-<version>-linux-x86_64 ~/.grok/bin/grok
ln -sfn ../downloads/grok-<version>-linux-x86_64 ~/.grok/bin/agent
```

Expect web search to break and turns to fail on slow requests again — those are
exactly the symptoms the patches address.

## Verifying it works

```bash
grok --version        # should read <version> (<branch-tip-sha>)
grok -p "Search the web for the latest stable release of PostgreSQL. \
         Reply with the version number and the source URL."
```

A reply carrying a live version plus a citation link confirms the whole path:
hosted web search reached the gateway, the `web_search_call` items parsed, and
the stream survived to completion.

## Upstream

These patches are **not** submitted upstream. `xai-org/grok-build` is a
read-only daily export from an internal monorepo and does not accept external
contributions. This branch exists purely as a local carry.
