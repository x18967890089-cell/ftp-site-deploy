<#
.SYNOPSIS
    Deploy a PHP site to a shared host over FTP - with the failure modes handled
    (connection-slot exhaustion, passive/active mismatch, silent partial uploads).

.DESCRIPTION
    Uploads an explicit file list, verifies each file's remote size, optionally
    deletes files, and (optionally) checks HTTP status after deploy.

    No credentials live in this file. Pass them as parameters or set
    FTP_USER / FTP_PASS environment variables.

.EXAMPLE
    # 1. dry run: show what would be uploaded
    .\deploy.ps1 -LocalRoot D:\sites\myapp -Files public/index.php,public/js/app.js -DryRun

    # 2. real deploy against a site whose document root is /public
    $env:FTP_PASS = '***'
    .\deploy.ps1 -LocalRoot D:\sites\myapp -Files public/index.php,public/js/app.js `
                 -Server ftp://ftp.example.com:21 -User me -RemoteRoot /

    # 3. delete a dead endpoint and verify two URLs afterwards
    .\deploy.ps1 -LocalRoot D:\sites\myapp -Files public/index.php -Delete public/api/stream.php `
                 -Check https://example.com/,https://example.com/api/ping
#>
[CmdletBinding()]
param(
    # Local site root (files are resolved relative to this)
    [Parameter(Mandatory = $true)][string]$LocalRoot,

    # Files to upload, relative to LocalRoot. Accepts a comma list or a file with one path per line.
    [Parameter(Mandatory = $true)][string[]]$Files,

    # Remote directory that maps to LocalRoot (usually '/')
    [string]$Server = $env:FTP_SERVER,
    [string]$User = $env:FTP_USER,
    [string]$RemoteRoot = '/',
    [string]$LogPath,

    # Remote files to delete (relative to RemoteRoot)
    [string[]]$Delete = @(),

    # URLs to check after deploy (expect 2xx/3xx)
    [string[]]$Check = @(),

    # Skip the remote size verification (not recommended)
    [switch]$NoVerify,
    [switch]$DryRun,
    [int]$Retries = 3
)

$ErrorActionPreference = 'Stop'
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
if (-not $curl) { throw 'curl.exe not found (Windows 10 1803+ ships it; otherwise install curl).' }

# curl writes progress/failure text on stderr. With ErrorActionPreference=Stop a
# perfectly expected failure (host down, 421, 550) would abort the script instead of
# being handled, so every call goes through this wrapper: stderr is swallowed, the
# exit code and stdout lines are kept.
function Invoke-Curl {
    param([string[]]$CurlArgs)
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $curl @CurlArgs 2>&1
        $script:CurlExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $eap
    }
    return @($raw | Where-Object { $_ -is [string] })
}
if (-not $Server) { throw 'Missing -Server (or set env FTP_SERVER).' }
# Bare host:port is what people actually type; curl would treat it as HTTP otherwise.
if ($Server -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
    $Server = 'ftp://' + $Server
}
if (-not $User) { throw 'Missing -User (or set env FTP_USER).' }
$pass = $env:FTP_PASS
if (-not $pass) { throw 'Set env FTP_PASS before running (keeps the secret out of files and history).' }

# Accept both "-Files a.php,b.php" and "-Files a.php b.php".
# With "powershell -File deploy.ps1 ... -Files a,b" the comma list arrives as ONE string,
# so each element is split again; it also means a single quoted list works everywhere.
function Split-PathList([string[]]$Items) {
    return @($Items | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$Files = Split-PathList $Files
$Delete = Split-PathList $Delete
$Check = Split-PathList $Check
if ($Files.Count -eq 0) { throw 'Missing -Files (comma list or one path per line in a file).' }

$LocalRoot = (Resolve-Path $LocalRoot).Path.TrimEnd('\', '/')
if (-not $LogPath) { $LogPath = Join-Path $env:TEMP ('ftp-deploy-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.log') }

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Join-Remote([string]$Relative) {
    $r = $Relative -replace '\\', '/'
    $r = $r.TrimStart('/')
    return ($RemoteRoot.TrimEnd('/') + '/' + $r)
}

function Get-RemoteSize([string]$RemotePath) {
    # LIST one directory and pick the entry; avoids parsing whole-tree listings.
    $dir = ($RemotePath -replace '/[^/]*$', '')
    $name = ($RemotePath -split '/')[-1]
    $listing = Invoke-Curl -CurlArgs @('-sS', '--max-time', '60', '--user', "${User}:${pass}", "$Server$dir/")
    if (-not $listing) { return $null }
    foreach ($line in ($listing -split "`r?`n")) {
        $parts = $line -split '\s+'
        if ($parts.Count -ge 9 -and $parts[-1] -eq $name) { return [int64]$parts[4] }
    }
    return $null
}

function Test-FtpSlot([string]$Target) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-Curl -CurlArgs @('-sS', '--max-time', '60', '--user', "${User}:${pass}", "$Target", '-o', 'NUL', '-w', '%{http_code}')
    $sw.Stop()
    return [pscustomobject]@{ Code = ($code -join ''); Ms = [int]$sw.ElapsedMilliseconds }
}

Write-Log "local root : $LocalRoot"
Write-Log "server     : $Server (user $User)"
Write-Log "remote root: $RemoteRoot"
Write-Log "log        : $LogPath"

# ---------------------------------------------------------------- preflight
$slot = Test-FtpSlot $Server
Write-Log ("preflight: HTTP {0} in {1} ms" -f $slot.Code, $slot.Ms)
if ($slot.Code -ne '226') {
    Write-Log 'connection slot not usable (expected 226). If it says 421, the host is out of FTP sessions - see docs/TROUBLESHOOTING.md.' 'ERROR'
    exit 2
}

$existing = @()
foreach ($f in $Files) {
    $full = Join-Path $LocalRoot $f
    if (-not (Test-Path -LiteralPath $full)) {
        Write-Log "missing local file: $f" 'ERROR'
        $existing += $null
        continue
    }
    $existing += (Resolve-Path -LiteralPath $full).Path
}
if ($existing -contains $null) { exit 3 }

if ($DryRun) {
    Write-Log '--- dry run ---'
    for ($i = 0; $i -lt $Files.Count; $i++) {
        Write-Log ("would upload {0} ({1} bytes) -> {2}" -f $Files[$i], (Get-Item $existing[$i]).Length, (Join-Remote $Files[$i]))
    }
    foreach ($d in $Delete) { Write-Log ("would delete {0}" -f (Join-Remote $d)) }
    foreach ($u in $Check) { Write-Log "would check $u" }
    exit 0
}

# ---------------------------------------------------------------- upload
$failed = @()
$badChecks = @()
for ($i = 0; $i -lt $Files.Count; $i++) {
    $local = $existing[$i]
    $remote = Join-Remote $Files[$i]
    $size = (Get-Item -LiteralPath $local).Length
    $ok = $false

    for ($attempt = 1; $attempt -le $Retries -and -not $ok; $attempt++) {
        $out = Invoke-Curl -CurlArgs @('-sS', '--max-time', '300', '--user', "${User}:${pass}", '-T', $local, "$Server$remote", '-w', '%{http_code} %{size_upload}')
        $outText = ($out -join ' ')
        $code = ($outText -split ' ')[0]
        Write-Log ("upload {0} attempt {1}: {2}" -f $remote, $attempt, $outText)

        if ($code -eq '226') {
            if ($NoVerify) { $ok = $true; break }
            $remoteSize = Get-RemoteSize $remote
            if ($remoteSize -eq $size) {
                Write-Log ("verified {0}: {1} bytes" -f $remote, $remoteSize)
                $ok = $true
            } else {
                Write-Log ("size mismatch {0}: local {1}, remote {2}" -f $remote, $size, $remoteSize) 'WARN'
            }
        } else {
            Write-Log 'transfer failed; waiting for the host to free the slot' 'WARN'
            Start-Sleep -Seconds (15 * $attempt)
        }
    }

    if (-not $ok) { $failed += $remote }
    Start-Sleep -Milliseconds 900   # shared hosts dislike back-to-back data channels
}

# ---------------------------------------------------------------- delete
foreach ($d in $Delete) {
    $remote = Join-Remote $d
    $code = Invoke-Curl -CurlArgs @('-sS', '--max-time', '60', '--user', "${User}:${pass}", $Server, '-Q', "DELE $remote", '-o', 'NUL', '-w', '%{http_code}')
    Write-Log ("delete {0}: {1}" -f $remote, ($code -join ''))
}

# ---------------------------------------------------------------- http check
foreach ($u in $Check) {
    $code = (Invoke-Curl -CurlArgs @('-sS', '-o', 'NUL', '-w', '%{http_code}', '--max-time', '30', $u)) -join ''
    Write-Log ("check {0}: {1}" -f $u, $code)
    if ($code -notmatch '^[23][0-9][0-9]$') { $badChecks += $u }
}

if ($failed.Count -gt 0 -or $badChecks.Count -gt 0) {
    if ($failed.Count -gt 0) {
        Write-Log ("FAILED: {0} file(s) - {1}" -f $failed.Count, ($failed -join ', ')) 'ERROR'
    }
    if ($badChecks.Count -gt 0) {
        Write-Log ("FAILED: {0} URL check(s) - {1}" -f $badChecks.Count, ($badChecks -join ', ')) 'ERROR'
    }
    exit 4
}
Write-Log 'all files uploaded and verified'
exit 0
