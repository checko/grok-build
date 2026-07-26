# Local patches: `patch/tolerate-unknown-sse-events`

This branch carries a small set of patches on top of upstream `xai-org/grok-build`
so that `grok` works against an **OpenAI-compatible passthrough gateway** using the
`responses` API backend, with hosted web search enabled.

Stock `grok` fails against such a gateway in three separate ways. Each patch fixes
one of them. All three are confined to a single file,
`crates/codegen/xai-grok-sampler/src/client.rs`, which is deliberate: that file
changes rarely upstream, so rebasing stays cheap.

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
| `e152220` | Skip unknown Responses stream events instead of failing the turn |
| `a8d8d2b` | Backfill `action` on in-progress `web_search_call` items |
| `14bcdfd` | Send `x_search` only to xAI-operated endpoints |
| `ad6fc19` | Add `update-and-install.sh` |

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
# Rust 1.92.0; pinned in rust-toolchain.toml, so rustup selects it automatically
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

Budget roughly 3–4 minutes for the release build and **26 GB** of disk for
`target/`.

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
# Grok Build - v0.2.112 (latest: 0.2.112) [stable]                        ← current
# A new version of Grok Build is available: 0.2.112 -> 0.2.113 [stable]   ← rebuild
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

## Updating

```bash
cd /path/to/grok-build-src
./update-and-install.sh
```

The script:

1. refuses to run on a dirty working tree
2. `git fetch upstream`
3. rebases this branch onto `upstream/main` (skipped when already current)
4. runs the four patch tests
5. `cargo build -p xai-grok-pager-bin --release`
6. copies to `~/.grok/downloads/grok-<version>-patched-linux-x86_64` and repoints
   `bin/grok` and `bin/agent`
7. prints the new version and the rollback command

It never pushes. To publish the rebased branch afterwards, note that rebasing
rewrites the commit SHAs, so a plain push is rejected:

```bash
git push --force-with-lease origin patch/tolerate-unknown-sse-events
```

### Known issue

`git checkout "$BRANCH"` sits inside the else-branch of the up-to-date test
(`update-and-install.sh:29`), so it only runs when there is something to rebase.
If you invoke the script while on `main` and upstream is already current, it
builds **`main`** and installs it under the `-patched-` name — silently replacing
the patched binary with an unpatched one. The test step does not catch this:
`cargo test` exits 0 when a filter matches no tests, so the four patch tests
simply report "0 passed".

Until that is fixed, confirm the branch before running:

```bash
git rev-parse --abbrev-ref HEAD    # must be patch/tolerate-unknown-sse-events
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
