$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetDir = Join-Path $Root "target\simplemarkdown-install"
$LibDir = Join-Path $Root "lib"
$Destination = Join-Path $LibDir "simplemarkdown-daemon.exe"

if (-not (Get-Command cargo -ErrorAction SilentlyContinue) -or
    -not (Get-Command rustc -ErrorAction SilentlyContinue)) {
    throw "Rust 1.88 or newer and Cargo are required."
}

$VersionLine = (rustc --version)
if ($VersionLine -notmatch '^rustc\s+(\d+)\.(\d+)\.') {
    throw "Could not determine the Rust version from: $VersionLine"
}
$Major = [int]$Matches[1]
$Minor = [int]$Matches[2]
if ($Major -lt 1 -or ($Major -eq 1 -and $Minor -lt 88)) {
    throw "Rust 1.88 or newer is required; found $VersionLine."
}

$HostLine = rustc -vV | Where-Object { $_ -like 'host: *' } | Select-Object -First 1
if (-not $HostLine) {
    throw "Could not determine the native Rust target."
}
$HostTriple = $HostLine.Substring(6).Trim()

cargo build `
    --manifest-path (Join-Path $Root "Cargo.toml") `
    --release `
    --locked `
    --target $HostTriple `
    --target-dir $TargetDir

$Source = Join-Path $TargetDir "$HostTriple\release\simplemarkdown-daemon.exe"
& $Source --self-test | Out-Null
New-Item -ItemType Directory -Force -Path $LibDir | Out-Null
$Temporary = Join-Path $LibDir (".simplemarkdown-daemon.{0}.tmp" -f [guid]::NewGuid())
try {
    Copy-Item -Force $Source $Temporary
    Move-Item -Force $Temporary $Destination
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $Temporary
}
Write-Host "Installed SimpleMarkdown backend to $Destination"
