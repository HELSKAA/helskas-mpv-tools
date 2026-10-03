# tools/build_release.ps1
# ---------------------------------------------------------------------------
# Builds the self-contained release zip for the GitHub Releases page.
#
#   powershell -ExecutionPolicy Bypass -File tools/build_release.ps1 -Version 1.0.1
#
# The zip contains EXACTLY what a user extracts into mpv's scripts/ folder:
#
#     helska.lua
#     helska/        (all modules + bundled tools, INCLUDING ffmpeg)
#
# Runtime junk (.unblocked, helska.conf, .helska-session-*, __pycache__, *.pyc)
# is never included.
# ---------------------------------------------------------------------------
param(
    [string]$Version = "1.0.1",
    [string]$Root    = (Split-Path -Parent $PSScriptRoot),
    [string]$OutDir  = (Join-Path (Split-Path -Parent $PSScriptRoot) "dist")
)
$ErrorActionPreference = "Stop"

$loader = Join-Path $Root "helska.lua"
$bundle = Join-Path $Root "helska"
if (-not (Test-Path $loader)) { throw "helska.lua not found in $Root" }
if (-not (Test-Path $bundle)) { throw "helska/ folder not found in $Root" }

$ffmpeg = @(Get-ChildItem (Join-Path $bundle "ffmpeg") -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "ffmpeg*" })
if ($ffmpeg.Count -eq 0) {
    Write-Warning "No ffmpeg binary in helska/ffmpeg - the release zip will lack audio clips + embedded-subtitle preload."
}

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("helska-release-" + [Guid]::NewGuid().ToString("N"))
$stageBundle = Join-Path $stage "helska"
New-Item -ItemType Directory -Force -Path $stageBundle | Out-Null
Copy-Item $loader (Join-Path $stage "helska.lua") -Force

$excludeDirs  = @("__pycache__")
$excludeFiles = @("*.pyc", "*.tmp", ".unblocked", ".helska-session-*", "helska.conf")

Get-ChildItem $bundle -Recurse -Force | ForEach-Object {
    $rel  = $_.FullName.Substring($bundle.Length).TrimStart("\")
    $dest = Join-Path $stageBundle $rel
    if ($_.PSIsContainer) {
        if ($excludeDirs -contains $_.Name) { return }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
    } else {
        foreach ($pat in $excludeFiles) { if ($_.Name -like $pat) { return } }
        $parent = Split-Path $dest -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item $_.FullName $dest -Force
    }
}

# FFmpeg's GPLv3 license text + written source offer live INSIDE helska/ffmpeg/
# (next to the binary), so they ship with the component and the zip root stays
# clean: just helska.lua + helska/. The bundle walk above already copies them;
# nothing is placed at the zip root. (See THIRD-PARTY-NOTICES.md.)

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path $OutDir ("helskas-mpv-tools-" + $Version + "-full.zip")
if (Test-Path $zip) { Remove-Item $zip -Force }

# NOTE: Windows PowerShell 5.1's Compress-Archive writes entry names with
# backslashes, which breaks extraction on anything that follows the ZIP spec
# (macOS/Linux unzip, many archivers). Build the archive by hand so every entry
# name uses forward slashes, exactly as the spec requires.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$fs   = [System.IO.File]::Open($zip, [System.IO.FileMode]::Create)
$arch = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in (Get-ChildItem $stage -Recurse -File)) {
        $rel = $f.FullName.Substring($stage.Length).TrimStart("\").Replace("\", "/")
        $entry = $arch.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
        $es    = $entry.Open()
        $input = [System.IO.File]::OpenRead($f.FullName)
        try { $input.CopyTo($es) } finally { $input.Dispose(); $es.Dispose() }
    }
} finally {
    $arch.Dispose()
    $fs.Dispose()
}
Remove-Item $stage -Recurse -Force

$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host ""
Write-Host ("Built " + $zip + "  (" + $size + " MB)")
Write-Host "Next: GitHub -> Releases -> Draft a new release -> attach this zip as an asset."
