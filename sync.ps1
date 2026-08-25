param(
    [string]$Owner  = "SchooiCodes",
    [string]$Repo   = "smt",
    [string]$Branch = "",
    [string]$LocalDir = $PSScriptRoot,
    [int]$Throttle = 8,
    [string[]]$ExcludePaths = @("config/settings.ini")
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
$headers = @{ "User-Agent" = "sync-script"; "Accept" = "application/vnd.github+json" }

function Get-GitHubErrorBody($exception) {
    if ($exception.Exception.Response) {
        try {
            $stream = $exception.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            return $reader.ReadToEnd()
        } catch {
            return "(could not read response body)"
        }
    }
    return $exception.Exception.Message
}

function Normalize-RelPath($p) {
    return ($p -replace '\\', '/').ToLowerInvariant()
}

function Get-GitBlobSha([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $header = [System.Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $full = New-Object byte[] ($header.Length + $bytes.Length)
    [Array]::Copy($header, 0, $full, 0, $header.Length)
    [Array]::Copy($bytes, 0, $full, $header.Length, $bytes.Length)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($full)
    } finally {
        $sha1.Dispose()
    }
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

$normalizedExcludes = $ExcludePaths | ForEach-Object { Normalize-RelPath $_ }

if (-not $Branch) {
    Write-Host "Detecting default branch..."
    try {
        $repoInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo" -Headers $headers
        $Branch = $repoInfo.default_branch
        Write-Host "Default branch: $Branch"
    } catch {
        Write-Host "Could not detect default branch: $(Get-GitHubErrorBody $_)"
        return
    }
}

Write-Host "Resolving branch to commit SHA..."
try {
    $commit = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/commits/$Branch" -Headers $headers
    $treeSha = $commit.commit.tree.sha
    Write-Host "Commit SHA: $($commit.sha)"
    Write-Host "Tree SHA:   $treeSha"
} catch {
    Write-Host "Failed to resolve branch '$Branch': $(Get-GitHubErrorBody $_)"
    return
}

if (-not $treeSha) {
    Write-Host "Tree SHA came back empty - dumping raw commit response:"
    $commit | ConvertTo-Json -Depth 5 | Write-Host
    return
}

$apiUrl  = "https://api.github.com/repos/$Owner/$Repo/git/trees/${treeSha}?recursive=1"
$rawBase = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch"

Write-Host "Fetching repo file list..."
try {
    $result = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    if ($result.truncated) {
        Write-Host "Warning: tree result was truncated by GitHub (very large repo)."
    }
    $tree = $result.tree | Where-Object { $_.type -eq 'blob' }
} catch {
    Write-Host "Failed to fetch tree: $(Get-GitHubErrorBody $_)"
    return
}

$toDownload = New-Object System.Collections.Generic.List[string]
$skippedExcluded = 0

foreach ($item in $tree) {
    $relNorm = Normalize-RelPath $item.path

    $isExcluded = $false
    foreach ($ex in $normalizedExcludes) {
        if ($relNorm -eq $ex -or $relNorm -like "*/$ex") {
            $isExcluded = $true
            break
        }
    }
    if ($isExcluded) {
        $skippedExcluded++
        continue
    }

    $localPath = Join-Path $LocalDir $item.path

    if (-not (Test-Path -LiteralPath $localPath)) {
        $toDownload.Add($item.path)
        continue
    }

    try {
        $localSha = Get-GitBlobSha -path $localPath
        if ($localSha -ne $item.sha) {
            $toDownload.Add($item.path)
        }
    } catch {
        Write-Host "Could not hash local file '$($item.path)', will re-download: $($_.Exception.Message)"
        $toDownload.Add($item.path)
    }
}

if ($skippedExcluded -gt 0) {
    Write-Host "Skipped $skippedExcluded excluded file(s): $($ExcludePaths -join ', ')"
}

if ($toDownload.Count -eq 0) {
    Write-Host "Nothing missing or changed."
    return
}

Write-Host "$($toDownload.Count) file(s) missing or changed. Downloading..."

$pool = [runspacefactory]::CreateRunspacePool(1, $Throttle)
$pool.Open()
$jobs = foreach ($relPath in $toDownload) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript({
        param($rawBase, $LocalDir, $relPath)
        $url = "$rawBase/$relPath"
        $outPath = Join-Path $LocalDir $relPath
        $outDir = Split-Path $outPath -Parent
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        try {
            Invoke-RestMethod -Uri $url -OutFile $outPath
            "OK: $relPath"
        } catch {
            "FAIL: $relPath ($($_.Exception.Message))"
        }
    }).AddArgument($rawBase).AddArgument($LocalDir).AddArgument($relPath)
    [pscustomobject]@{ Pipe = $ps; Handle = $ps.BeginInvoke() }
}

foreach ($j in $jobs) {
    Write-Host ($j.Pipe.EndInvoke($j.Handle))
    $j.Pipe.Dispose()
}
$pool.Close()
$pool.Dispose()

Write-Host "Done."
