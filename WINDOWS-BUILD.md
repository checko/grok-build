# Building the patched `grok` on Windows

`PATCHES.md` covers the patches themselves and the Linux install path. This
document covers Windows, where stock `cargo build` does **not** work out of the
box — three separate things fail, none of them related to the patches. All three
are handled by `build-and-install-windows.ps1`; this file explains what they are
so the workarounds are not cargo-cult.

Target: `x86_64-pc-windows-msvc`. Verified on Windows 11 Pro 26200, producing
`grok 0.2.112 (35ec58a)`.

## Prerequisites

Roughly 30 GB of free disk (`target/` alone reaches ~13 GB) and admin rights for
the toolchain install.

### 1. Rust

The toolchain is pinned to 1.92.0 by `rust-toolchain.toml`, so rustup selects it
automatically — no manual `rustup default` needed.

```powershell
choco install -y rustup.install
```

`rust-toolchain.toml` also lists the two Linux targets. rustup downloads their
standard libraries on first build; that is expected and harmless on Windows.

### 2. MSVC C++ build tools

Rust needs a linker. The MSVC toolchain is the tier-1 default and matches how
official Windows binaries are produced.

```powershell
choco install -y visualstudio2022-workload-vctools
```

This is a multi-GB download and takes considerable time. **Do not run it under a
wrapper that can time out and kill it** — a half-finished install leaves
`vswhere -format json` reporting `"isComplete": false`, and `cl.exe` may exist
while the Windows SDK is still missing. To resume an interrupted install:

```powershell
& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe" modify `
    --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" `
    --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended `
    --quiet --norestart --nocache
```

Confirm before building — both must be present:

```powershell
& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -all -products * -format json |
    Select-String '"isComplete"'
Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Lib" | Select-Object -Expand Name
```

### 3. protoc 29.3 for Windows

`bin/protoc` in this repo is a [dotslash](https://dotslash-cli.com/) wrapper
around platform-specific binaries. On Windows it is neither a dotslash install
nor a Win32 executable, so running it fails with `os error 193` and the build
script aborts:

```
bin/protoc found at `..\..\..\bin/protoc` but failed to execute:
Failed to execute protoc: %1 is not a valid Win32 application (os error 193)
`protoc` not found; likely it is missing in docker image
```

The lookup order in `crates/build/xai-proto-build/src/find_protoc.rs` is
`$PROTOC` → `bin/protoc` → `PATH`, so setting `$PROTOC` takes priority. Use the
**same pinned version** the wrapper declares — 29.3:

```powershell
$zip = "$env:TEMP\protoc-29.3-win64.zip"
Invoke-WebRequest -UseBasicParsing `
    -Uri "https://github.com/protocolbuffers/protobuf/releases/download/v29.3/protoc-29.3-win64.zip" `
    -OutFile $zip
Expand-Archive $zip -DestinationPath "C:\d\test\claude\grok-build\protoc-29.3-win64" -Force
```

Keep the extracted layout intact (`bin\protoc.exe` next to `include\`) — the
build resolves the well-known-types include directory as `../include` relative
to the binary.

## The two source-level problems

### `/dev/stdout` and `/dev/null` in the proto build script

`emit_rerun_if_changed` in `crates/build/xai-proto-build/src/lib.rs` invoked
protoc with `--dependency_out=/dev/stdout --descriptor_set_out=/dev/null` and
parsed the result off stdout. Neither device path exists on Windows, so protoc
exited with `/dev/stdout: No such file or directory`.

Fixed in-tree (commit `c446dfc`): both outputs go to scratch files under
`OUT_DIR` on every platform, the dependency list is read back from that file,
and the prefix check matches the real descriptor path instead of the literal
`/dev/null:`. The well-known-types filter also accepts backslash-separated
paths.

This function only emits `cargo:rerun-if-changed=` lines. Actual code generation
runs through a separate `file_descriptor_set_path` in `compile_protos` and is
untouched, so generated code is identical on every platform.

### `LNK1318` on the final link

Linking `xai-grok-pager-bin` fails with:

```
LINK : fatal error LNK1318: Unexpected PDB error; LIMIT (12) ''
```

rustc always passes `/DEBUG` on MSVC targets, and the PDB for a workspace this
size (257 object files plus several hundred rlibs) exceeds what `link.exe` can
emit. Two obvious remedies do **not** work — both were tried and both still
fail with the same error:

- `-C link-arg=/PDBPAGESIZE:8192` — raises the PDB size ceiling, but this is not
  the limit being hit
- `-C strip=symbols`

What works is suppressing PDB generation for the final link:

```
-C link-arg=/DEBUG:NONE
```

Use `cargo rustc`, not `cargo build`. `cargo rustc` applies the extra flag to the
final crate only, so cached dependency artifacts stay valid. Putting the same
flag in `RUSTFLAGS` would change the fingerprint of every crate and force a
full rebuild.

Note the `LINK` environment variable — normally honoured by `link.exe` — did
**not** take effect here. The flag has to go through rustc.

The only cost is that the Windows binary ships without a PDB, so Windows
backtraces carry less symbol detail. Nothing functional changes.

## Building

```powershell
.\build-and-install-windows.ps1
```

Override the protoc location with `$env:PROTOC` and the install root with
`$env:GROK_HOME` if your paths differ from the defaults in the script.

Equivalent manual steps:

```powershell
$env:PATH   = "$env:USERPROFILE\.cargo\bin;$env:PATH"
$env:PROTOC = "C:\d\test\claude\grok-build\protoc-29.3-win64\bin\protoc.exe"

cargo test --release -p xai-grok-sampler --lib -- `
    unknown_top_level nested_unknown web_search_call xai_hosted deserialize_response_event

cargo rustc -p xai-grok-pager-bin --release --bin xai-grok-pager -- -C link-arg=/DEBUG:NONE
```

Nine tests should pass. The binary lands at
`target\release\xai-grok-pager.exe` (~130 MB).

Budget **35–45 minutes** for a cold build. Running the tests with `--release`
rather than the default debug profile is deliberate: the artifacts are shared
with the release build that follows, so the workspace is compiled once instead
of twice.

## Installing

Windows has no symlinks in `~\.grok\bin` — both entry points are **real file
copies**, unlike the Linux layout described in `PATCHES.md`. `agent.exe` is what
spawned subagents exec, so it must be replaced too.

```powershell
$v   = "0.2.112"
$art = "$env:USERPROFILE\.grok\downloads\grok-$v-patched-windows-x86_64.exe"

Copy-Item target\release\xai-grok-pager.exe $art -Force
Copy-Item $art "$env:USERPROFILE\.grok\bin\grok.exe"  -Force
Copy-Item $art "$env:USERPROFILE\.grok\bin\agent.exe" -Force
```

Close any running `grok` / `agent` process first — Windows locks running
executables and the copy will fail.

The stock download (`grok-windows-x86_64.exe`) is never deleted, so rollback is
just copying it back:

```powershell
Copy-Item "$env:USERPROFILE\.grok\downloads\grok-windows-x86_64.exe" `
          "$env:USERPROFILE\.grok\bin\grok.exe" -Force   # and agent.exe
```

## Required configuration

In `%USERPROFILE%\.grok\config.toml`:

```toml
[cli]
auto_update = false                # REQUIRED — see PATCHES.md

[model.<your-model-id>]
base_url = "http://<your-passthrough>/v1"
api_backend = "responses"          # the patches only matter on this backend
supports_backend_search = true
```

Without `auto_update = false` the updater will overwrite `bin\grok.exe` with a
stock build on a later launch. On `api_backend = "chat_completions"` the patched
binary runs fine but behaves exactly like stock — none of the three patches are
on that code path.

## Verifying

```powershell
& "$env:USERPROFILE\.grok\bin\grok.exe" --version    # grok 0.2.112 (35ec58a) [stable]
& "$env:USERPROFILE\.grok\bin\agent.exe" --version   # must match
grok update --check                                  # read-only; never plain `grok update`

grok -p "Search the web for the latest stable release of PostgreSQL. Reply with the version number and the source URL."
```

A reply carrying a live version plus a citation link confirms the whole path:
hosted web search reached the gateway, the `web_search_call` items parsed, and
the stream survived unknown SSE events.

## Rebuilding after an upstream bump

Rebase as described in `PATCHES.md` (that part is platform-independent), then
re-run `.\build-and-install-windows.ps1`. Note `update-and-install.sh` is
Linux-only — it uses `cp`, `chmod`, and `ln -sfn`, and installs under a
`-linux-x86_64` artifact name.

Because the branch now carries a build-tooling commit in
`crates/build/xai-proto-build/src/lib.rs` as well as the sampler patches in
`crates/codegen/xai-grok-sampler/src/client.rs`, a rebase has two files that
could conflict rather than one. Both change rarely upstream.
