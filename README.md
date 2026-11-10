# ftp-site-deploy

[![ci](https://github.com/x18967890089-cell/ftp-site-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/x18967890089-cell/ftp-site-deploy/actions/workflows/ci.yml)

On a shared PHP host you get FTP and nothing else: no SSH, no CI, no atomic release.
This repository is the deploy path that survived that reality — a small PowerShell
script that uploads an explicit file list, verifies every remote byte count, and
refuses to pretend it succeeded.

It exists because "WinSCP said 100% but the site still shows the old CSS" and
"421 Too many connections" are not edge cases on a shared host. They are Tuesday.

```
Local checkout ──(curl -T, one file at a time)──▶ FTP server ──▶ PHP-FPM/Apache
        │                                            │
        └──── remote size compare ───────────────────┘
```

## What it does

| Step | Behaviour |
| --- | --- |
| Preflight | Opens one FTP session and requires `226`. A `421` means the host is out of sessions — the script stops instead of hammering it. |
| Resolve | Every file in `-Files` must exist locally, or the run aborts before touching the server (`exit 3`). |
| Upload | `curl -T` per file, one data channel at a time, 900 ms apart, with up to `-Retries` attempts. |
| Verify | Compares the remote byte count against the local one. Mismatch is a failure, not a warning. |
| Delete | Removes remote files via FTP `DELE` (for endpoints you deliberately retired). |
| Check | Optionally probes URLs and prints HTTP status after the deploy. |
| Result | `exit 0` only if every file uploaded and verified; `exit 4` otherwise. |

## Tested against a real FTP server, not a mock

Two jobs run on `windows-latest` for every push:

| Job | What actually happens |
| --- | --- |
| `static` | The script is parsed by Windows PowerShell 5.1's own parser (0 errors), every byte is checked to be ASCII (a non-ASCII byte is what breaks quoting when a no-BOM file is read as ANSI), and PSScriptAnalyzer runs with `-Severity Error`. |
| `e2e` | A throwaway `pyftpdlib` server is started on port 2121, then the script really uploads two files: exit `0`, both remote byte counts match, the log contains `verified`, a second run is still idempotent, `-Delete` removes the target (`226`), `-DryRun` prints `would upload`, and a missing local file exits `3`. |

That is the whole point of the repository: the failure modes are the product, so they are
reproduced in CI instead of described in prose.

## Quick start

```powershell
# 1. see the plan without touching anything
.\deploy.ps1 -LocalRoot D:\sites\myapp `
             -Files public/index.php,public/js/app.js `
             -Server ftp://ftp.example.com:21 -User me -DryRun

# `-Files` accepts a comma list either way: -Files a.php,b.php  or  -Files 'a.php,b.php'
# (the quoted form is what survives "powershell -File deploy.ps1 ..." from a scheduler)

# 2. deploy (secret via environment, never in the file)
$env:FTP_PASS = '***'
.\deploy.ps1 -LocalRoot D:\sites\myapp `
             -Files public/index.php,public/js/app.js `
             -Server ftp://ftp.example.com:21 -User me -RemoteRoot /

# 3. retire a dead endpoint and verify the site afterwards
.\deploy.ps1 -LocalRoot D:\sites\myapp `
             -Files public/index.php `
             -Server ftp://ftp.example.com:21 -User me `
             -Delete public/api/stream.php `
             -Check https://example.com/,https://example.com/api/ping
```

`-Files` accepts a comma list or multiple values: `-Files a.php,b.js,c.css`.

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-LocalRoot` | — | Local site root; all `-Files` paths are relative to it. |
| `-Files` | — | Files to upload. Explicit list — never "the whole tree". |
| `-Server` | `$env:FTP_SERVER` | `ftp://host:port` (add `ftps://` for implicit TLS if the host supports it). |
| `-User` | `$env:FTP_USER` | FTP account. |
| `-RemoteRoot` | `/` | Remote directory that maps to `-LocalRoot`. |
| `-Delete` | empty | Remote files to delete, relative to `-RemoteRoot`. |
| `-Check` | empty | URLs to probe after deploy. |
| `-NoVerify` | off | Skip the remote size comparison (rarely what you want). |
| `-DryRun` | off | Print the plan and exit 0. |
| `-Retries` | `3` | Attempts per file. |
| `-LogPath` | `%TEMP%\ftp-deploy-*.log` | Append-only log of the run. |

Exit codes: `0` success · `2` host has no free FTP session · `3` local file missing · `4` at least one upload/verify failed.

## Why an explicit file list

Deploying `public/` wholesale means the run also pushes whatever happens to be in
your working tree — a debug `config.php`, a `storage/` cache, a half-finished page.
Naming files keeps the blast radius equal to the change you actually tested, and it
makes the remote size check meaningful.

## Scope

This is a single-host, sequential, no-downtime-window deploy tool. It is not a
release manager: no rollback, no atomic symlink switch, no concurrency. On a host
that gives you SSH, use `rsync --delay-updates` or a real release directory instead
(see the sibling `ubuntu-php-deploy` style flow).

## Requirements

Windows PowerShell 5.1 or PowerShell 7+, and `curl.exe` (shipped with Windows 10
1803+, present in Linux/macOS by default).

## License

MIT — see [LICENSE](LICENSE). Troubleshooting lives in
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
