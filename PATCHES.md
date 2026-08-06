# Local patches: `patch/tolerate-unknown-sse-events`

This branch carries a small set of patches on top of upstream `xai-org/grok-build`
so that `grok` works against an **OpenAI-compatible passthrough gateway** using the
`responses` API backend, with hosted web search enabled.

Stock `grok` fails against such a gateway in three separate ways. Each patch fixes
one of them. All three are confined to a single file,
`crates/codegen/xai-grok-sampler/src/client.rs`, which is deliberate: keeping the
blast radius to one file keeps rebases cheap. That file does churn upstream —
the 0.2.112 → 0.2.120 sync rewrote 490 of its lines — but the patches sit in
distinct enough regions that the rebases have so far been conflict-free.

## Branch layout

```
patch/tolerate-unknown-sse-events   ← the patches live here (this branch)
main                                ← untouched mirror of upstream/main
```

`main` is never patched. It is kept byte-identical to `upstream/main` so the
patch branch can always be replayed onto a fresh upstream with a plain rebase.

Remotes:

| remote | URL |
|---|---|
| `origin` | `git@github.com:checko/grok-build.git` (the fork) |
| `upstream` | `https://github.com/xai-org/grok-build.git` |

## What the patches do

| commit | fix |
|---|---|
| `84ba2c9` | Skip unknown Responses stream events instead of failing the turn |
| `451f7c8` | Backfill `action` on in-progress `web_search_call` items |
| `68aa33c` | Send `x_search` only to xAI-operated endpoints |
| `a19943f` | Add `update-and-install.sh` |

Rebasing rewrites those SHAs every time, so they are indicative only — read the
live stack with `git log --oneline upstream/main..HEAD`. The table above is as
of the rebase onto upstream `a5589e9` (v0.2.120).

**None of the three has been adopted upstream as of v0.2.120.** Verified there:
`deserialize_response_event` still strips only unparseable `/response/tools`
entries and returns `SamplingError::Serialization` on everything else;
`retry.rs` still classifies that error as fatal on the first attempt; and
`extra_tool_entries` is still called with no host gate. Expect to keep carrying
these.

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
whole request with `HTTP 400 Unsupported tool type: x_search`. The patch gates
xAI-only hosted tools on the endpoint host, so they ship to `*.x.ai` and
`*.grok.com` but not to third-party gateways. Nothing needs configuring — the
host is read from `base_url`.

Four unit tests cover the patches. Run them with:

```bash
cargo test -p xai-grok-sampler --lib -- \
  unknown_top_level nested_unknown web_search_call xai_hosted
```

## Installing on another machine

The target machine is assumed to already have stock `grok` installed, so that
`~/.grok/bin/` and `~/.grok/downloads/` exist.

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
# The toolchain is pinned in rust-toolchain.toml (1.94.0 as of v0.2.120) and
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
(short-circuit at `crates/codegen/xai-grok-update/src/auto_update.rs:468`; the
setting defaults to true).

## Checking for updates

`auto_update = false` disables the *startup* check as well as the download, so
`grok` will never tell you a new version exists. Check on demand instead:

```bash
grok update --check
# Grok Build - v0.2.120 (latest: 0.2.120)                        ← current
# A new version of Grok Build is available: 0.2.120 -> 0.2.121   ← rebuild
```

This works despite the pin because `check_update_status`
(`crates/codegen/xai-grok-update/src/auto_update.rs:102`) never consults
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

### Why `--version` says `[alpha]`

A self-built binary reports e.g. `grok 0.2.120 (3c5009f) [alpha]`. That label is
cosmetic and does **not** mean the build is on the alpha channel.
`channel_label()` (`crates/codegen/xai-grok-update/src/version.rs:554`) compares
the compiled version against the `stable_version` cached in
`~/.grok/version.json` and labels anything ahead of it as alpha. Because
`auto_update = false` stops that cache being refreshed, the pointer stays frozen
at whatever the last stock install wrote, and every locally-built version will
read `[alpha]` from then on. Nothing is affected functionally.

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
5. runs the patch tests, then asserts by name that all four actually reported
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

Conflicts can only realistically appear in `client.rs`. Resolve, then:

```bash
git rebase --continue
./update-and-install.sh
```

To bail out entirely: `git rebase --abort`.

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
