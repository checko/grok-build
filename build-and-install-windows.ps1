# Build the patched grok on Windows and point ~/.grok/bin at the result.
#
# The Windows counterpart of update-and-install.sh. It does not rebase onto
# upstream -- run that separately if needed. The stock binary is left in
# ~/.grok/downloads, so rollback is just copying it back (printed at the end).
#
# Prerequisites (one-time):
#   choco install -y rustup.install visualstudio2022-workload-vctools
#   protoc 29.3 for Windows extracted somewhere, see $Protoc below
$ErrorActionPreference = 'Stop'

$Repo      = $PSScriptRoot
$GrokHome  = if ($env:GROK_HOME) { $env:GROK_HOME } else { "$env:USERPROFILE\.grok" }
$Stock     = "grok-windows-x86_64.exe"

# The repo vendors `bin/protoc` as a dotslash wrapper around a Linux binary,
# which cannot execute on Windows. Point PROTOC at the Windows build of the
# same pinned version (29.3, see bin/protoc).
$Protoc = if ($env:PROTOC) { $env:PROTOC } else { "C:\d\test\claude\grok-build\protoc-29.3-win64\bin\protoc.exe" }
if (-not (Test-Path $Protoc)) {
    throw "protoc not found at $Protoc -- download protoc-29.3-win64.zip from " +
          "https://github.com/protocolbuffers/protobuf/releases/tag/v29.3 and set `$env:PROTOC"
}
$env:PROTOC = $Protoc
$env:PATH   = "$env:USERPROFILE\.cargo\bin;$env:PATH"

Set-Location $Repo

Write-Host "==> testing the patches"
cargo test --release -p xai-grok-sampler --lib -- `
    unknown_top_level nested_unknown web_search_call xai_hosted deserialize_response_event
if ($LASTEXITCODE -ne 0) { throw "patch tests failed" }

# `cargo rustc` rather than `cargo build`: /DEBUG:NONE has to reach the final
# link only. rustc always passes /DEBUG on MSVC, and the resulting PDB for this
# workspace trips `LNK1318: Unexpected PDB error; LIMIT (12)` -- the PDB exceeds
# what link.exe can emit, and /PDBPAGESIZE does not raise that particular limit.
# Dropping the PDB costs symbol detail in Windows backtraces, nothing else.
Write-Host "==> building (a few minutes)"
cargo rustc -p xai-grok-pager-bin --release --bin xai-grok-pager -- -C link-arg=/DEBUG:NONE
if ($LASTEXITCODE -ne 0) { throw "build failed" }

$version  = (Select-String -Path "$Repo\crates\codegen\xai-grok-version\Cargo.toml" `
                           -Pattern '^version\s*=\s*"([^"]+)"' | Select-Object -First 1).Matches[0].Groups[1].Value
$artifact = "grok-$version-patched-windows-x86_64.exe"

Write-Host "==> installing $artifact"
Copy-Item "$Repo\target\release\xai-grok-pager.exe" "$GrokHome\downloads\$artifact" -Force
# Windows has no symlinks here -- both entry points are real copies. `agent.exe`
# is what subagent spawns exec, so it has to be replaced too.
Copy-Item "$GrokHome\downloads\$artifact" "$GrokHome\bin\grok.exe"  -Force
Copy-Item "$GrokHome\downloads\$artifact" "$GrokHome\bin\agent.exe" -Force

Write-Host "==> done: $(& "$GrokHome\bin\grok.exe" --version)"
Write-Host "    rollback: Copy-Item $GrokHome\downloads\$Stock $GrokHome\bin\grok.exe -Force (and agent.exe)"
