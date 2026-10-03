# tools/check_github_limits.ps1
# ---------------------------------------------------------------------------
# Safety net to run before `git push`:
#   * fails if any file that WOULD be committed exceeds GitHub's 100 MiB
#     per-file hard limit (push is rejected otherwise);
#   * prints the largest files that would be committed.
# Requires `git init` to have been run (uses git ls-files).
# ---------------------------------------------------------------------------
param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$limit = 100MB
Push-Location $Root
try {
    $paths = git ls-files --cached --others --exclude-standard
    if (-not $paths) { Write-Host "Nothing to commit yet."; return }

    $files = $paths |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        ForEach-Object { Get-Item -LiteralPath $_ } |
        Sort-Object Length -Descending

    Write-Host ("Files that would be committed: " + $files.Count)
    Write-Host "Largest 15:"
    $files | Select-Object -First 15 | ForEach-Object {
        "{0,10:N1} MiB  {1}" -f ($_.Length / 1MB), $_.FullName.Substring($Root.Length + 1)
    }

    $over = @($files | Where-Object { $_.Length -ge $limit })
    if ($over.Count -gt 0) {
        Write-Host ""
        Write-Host ("BLOCKED: " + $over.Count + " file(s) exceed GitHub's 100 MiB limit:")
        $over | ForEach-Object { Write-Host ("   " + $_.FullName) }
        exit 1
    }
    Write-Host ""
    Write-Host "OK - nothing exceeds the 100 MiB GitHub limit."
}
finally { Pop-Location }
