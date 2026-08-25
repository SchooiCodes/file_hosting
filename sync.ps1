param(
    [string]$Owner  = "SchooiCodes",
    [string]$Repo   = "smt",
    [string]$Branch = "",
    [string]$LocalDir = $PSScriptRoot,
    [int]$Throttle = 16,
    [string[]]$ExcludePaths = @("config/settings.ini")
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max(64, $Throttle * 4)
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

# ---- Phase 1: cheap filtering (no hashing yet) ----
# - Missing locally               -> definite download
# - Same size as remote           -> queue for a raw content hash check (cheap path)
# - Different size from remote    -> queue for a line-ending-aware check, since a
#   pure CRLF<->LF conversion (e.g. from git's core.autocrlf on checkout) changes
#   the byte count without the content actually differing
$definiteDownload  = New-Object System.Collections.Generic.List[string]
$needsHashCheck    = New-Object System.Collections.Generic.List[object]
$needsLineEndCheck = New-Object System.Collections.Generic.List[object]
$skippedExcluded   = 0

foreach ($item in $tree) {
    $relNorm = Normalize-RelPath $item.path

    $isExcluded = $false
    foreach ($ex in $normalizedExcludes) {
        if ($relNorm -eq $ex -or $relNorm -like "*/$ex") { $isExcluded = $true; break }
    }
    if ($isExcluded) { $skippedExcluded++; continue }

    $localPath = Join-Path $LocalDir $item.path
    $fi = [System.IO.FileInfo]::new($localPath)

    if (-not $fi.Exists) {
        $definiteDownload.Add($item.path)
        continue
    }
    if ($fi.Length -eq [int64]$item.size) {
        $needsHashCheck.Add($item)
    } else {
        $needsLineEndCheck.Add($item)
    }
}

if ($skippedExcluded -gt 0) {
    Write-Host "Skipped $skippedExcluded excluded file(s): $($ExcludePaths -join ', ')"
}
Write-Host "$($definiteDownload.Count) file(s) missing locally."
Write-Host "$($needsHashCheck.Count) file(s) need a content hash check (size unchanged)."
Write-Host "$($needsLineEndCheck.Count) file(s) need a line-ending-aware check (size differs)."

# ---- Phase 2: parallel hash check (same-size files) ----
# Streams the file straight through SHA1 in chunks (never buffers header+content
# into one big extra byte array), and runs across a runspace pool so many files
# hash concurrently instead of one at a time.
$hashResults = New-Object System.Collections.Generic.List[string]

if ($needsHashCheck.Count -gt 0) {
    $pool1 = [runspacefactory]::CreateRunspacePool(1, $Throttle)
    $pool1.Open()
    $hashJobs = foreach ($item in $needsHashCheck) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool1
        [void]$ps.AddScript({
            param($LocalDir, $relPath, $expectedSha)

            $localPath = Join-Path $LocalDir $relPath
            $sha1 = [System.Security.Cryptography.SHA1]::Create()
            try {
                $fs = [System.IO.File]::OpenRead($localPath)
                try {
                    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes("blob $($fs.Length)`0")
                    [void]$sha1.TransformBlock($headerBytes, 0, $headerBytes.Length, $null, 0)

                    $buffer = New-Object byte[] 1MB
                    while (($read = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        [void]$sha1.TransformBlock($buffer, 0, $read, $null, 0)
                    }
                    [void]$sha1.TransformFinalBlock([byte[]]::new(0), 0, 0)
                    $hex = ([BitConverter]::ToString($sha1.Hash) -replace '-', '').ToLowerInvariant()
                } finally {
                    $fs.Dispose()
                }
            } finally {
                $sha1.Dispose()
            }

            if ($hex -ne $expectedSha) { $relPath } else { $null }
        }).AddArgument($LocalDir).AddArgument($item.path).AddArgument($item.sha)
        [pscustomobject]@{ Pipe = $ps; Handle = $ps.BeginInvoke(); Path = $item.path }
    }

    foreach ($j in $hashJobs) {
        try {
            $r = $j.Pipe.EndInvoke($j.Handle)
            if ($r) { $hashResults.Add($r) }
        } catch {
            Write-Host "Hash check failed for '$($j.Path)', will re-download: $($_.Exception.Message)"
            $hashResults.Add($j.Path)
        }
        $j.Pipe.Dispose()
    }
    $pool1.Close()
    $pool1.Dispose()
}

# ---- Phase 2b: parallel line-ending-aware check (size-mismatched files) ----
# Reads the whole file, checks a null byte to rule out binary content, and if
# it's text, strips CRLF -> LF and re-hashes as a git blob would be hashed.
# If THAT matches the remote SHA, the only real difference was line endings
# (e.g. checked out through git with core.autocrlf=true) and it's treated as
# unchanged. Anything binary, or still mismatched after normalizing, gets
# queued for download.
$lineEndResults = New-Object System.Collections.Generic.List[string]

if ($needsLineEndCheck.Count -gt 0) {
    $pool1b = [runspacefactory]::CreateRunspacePool(1, $Throttle)
    $pool1b.Open()
    $leJobs = foreach ($item in $needsLineEndCheck) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool1b
        [void]$ps.AddScript({
            param($LocalDir, $relPath, $expectedSha)

            $localPath = Join-Path $LocalDir $relPath
            $bytes = [System.IO.File]::ReadAllBytes($localPath)

            # Binary heuristic: a NUL byte in the first 8000 bytes (same idea git uses)
            $scanLen = [Math]::Min(8000, $bytes.Length)
            $isBinary = $scanLen -gt 0 -and ([Array]::IndexOf($bytes, [byte]0, 0, $scanLen) -ge 0)

            if ($isBinary) {
                # Real binary content of a different size = a real change
                return $relPath
            }

            # Strip CRLF -> LF
            $normalized = New-Object System.Collections.Generic.List[byte] ($bytes.Length)
            for ($i = 0; $i -lt $bytes.Length; $i++) {
                if ($bytes[$i] -eq 0x0D -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 0x0A) {
                    continue  # drop the CR, the LF gets added on the next iteration
                }
                $normalized.Add($bytes[$i])
            }
            $normBytes = $normalized.ToArray()

            $header = [System.Text.Encoding]::ASCII.GetBytes("blob $($normBytes.Length)`0")
            $full = New-Object byte[] ($header.Length + $normBytes.Length)
            [Array]::Copy($header, 0, $full, 0, $header.Length)
            [Array]::Copy($normBytes, 0, $full, $header.Length, $normBytes.Length)

            $sha1 = [System.Security.Cryptography.SHA1]::Create()
            try {
                $hash = $sha1.ComputeHash($full)
            } finally {
                $sha1.Dispose()
            }
            $hex = ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()

            if ($hex -ne $expectedSha) { $relPath } else { $null }
        }).AddArgument($LocalDir).AddArgument($item.path).AddArgument($item.sha)
        [pscustomobject]@{ Pipe = $ps; Handle = $ps.BeginInvoke(); Path = $item.path }
    }

    foreach ($j in $leJobs) {
        try {
            $r = $j.Pipe.EndInvoke($j.Handle)
            if ($r) { $lineEndResults.Add($r) }
        } catch {
            Write-Host "Line-ending check failed for '$($j.Path)', will re-download: $($_.Exception.Message)"
            $lineEndResults.Add($j.Path)
        }
        $j.Pipe.Dispose()
    }
    $pool1b.Close()
    $pool1b.Dispose()
}

$toDownload = New-Object System.Collections.Generic.List[string]
$toDownload.AddRange($definiteDownload)
$toDownload.AddRange($hashResults)
$toDownload.AddRange($lineEndResults)

if ($toDownload.Count -eq 0) {
    Write-Host "Nothing missing or changed."
    return
}

Write-Host "$($toDownload.Count) file(s) missing or changed. Downloading..."

# ---- Phase 3: parallel download ----
$pool2 = [runspacefactory]::CreateRunspacePool(1, $Throttle)
$pool2.Open()
$jobs = foreach ($relPath in $toDownload) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool2
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
$pool2.Close()
$pool2.Dispose()

Write-Host "Done."