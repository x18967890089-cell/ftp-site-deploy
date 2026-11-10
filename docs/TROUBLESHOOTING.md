# Troubleshooting

Every entry below is a failure that actually happened on a shared PHP host, in the
order you are most likely to meet it. Each one names the symptom you see, the cause,
and the fix.

## 1. `421` / "Too many connections" / "5 users (the maximum) are already logged in"

**Symptom**

```
curl: (67) Access denied: 421
Response: 421 Too many connections (5) from this IP, please try again later
```

or from WinSCP / FileZilla:

```
5 users (the maximum) are already logged in
```

**Cause** — shared hosts cap *concurrent FTP sessions per account* (commonly 5).
Every attempt that times out half-open still holds a slot until the server reaps it.
A GUI client left open, a failed batch script, and a probe request can together fill
the quota, and then every new transfer is refused before it starts.

**Fix**

1. Close GUI FTP clients (they keep a control channel open even when idle).
2. Kill leftover automation processes, then wait — slots are reaped on the server
   side, usually within one to two minutes:

   ```powershell
   Get-Process WinSCP -ErrorAction SilentlyContinue | Stop-Process -Force
   Start-Sleep -Seconds 120
   ```

3. Prove you have a slot before deploying. `226` means the transfer completed; a
   bare connect that returns `226` means the session was accepted:

   ```powershell
   curl.exe -sS --max-time 60 --user "$env:FTP_USER:$env:FTP_PASS" `
            ftp://ftp.example.com:21/ -o NUL -w "%{http_code}"
   ```

4. Deploy one file at a time, with a pause between files. `deploy.ps1` does this by
   default (900 ms) and stops with `exit 2` instead of retrying into a full quota.

Do **not** add retries with no delay here. Retrying a `421` quickly keeps the quota
occupied and makes recovery take longer.

## 2. `Transfer channel can't be opened` / connection refused on the data port

**Symptom**

```
Transfer channel can't be opened. Reason: No connection could be made because
the target machine actively refused it.
```

**Cause** — passive mode asks the server for a data port and your side cannot reach
it. Common on hosts behind NAT or a firewall that only forwards the control port.

**Fix**

- Try the other mode once, explicitly:

  ```powershell
  # passive (default for most clients)
  curl.exe -sS -P - -T file.php ftp://host/path/file.php
  # active
  curl.exe -sS -P - --ftp-port - -T file.php ftp://host/path/file.php
  ```

- If passive works with `curl` but not with a GUI client, the client is caching a
  stale network profile — delete the saved session and reconnect.
- If neither mode works, the host is not reachable for data transfer at all. That is
  a support ticket, not a script problem.

## 3. Upload says `226` but the site still serves the old file

Three different causes, in order of likelihood:

1. **Wrong remote path.** `/public/api/x.php` and `/api/x.php` are different files when
   the document root is `/public`. Print the resolved remote path and compare with the
   web root you actually browse.
2. **Upload silently truncated.** Compare byte counts; `deploy.ps1` does this and
   treats a mismatch as a failure. A file that uploads as 0 bytes usually means the
   data channel died mid-transfer.
3. **Server-side caching.** PHP OPcache (`opcache.validate_timestamps=0`) or a
   reverse proxy keeps serving the compiled/old copy. Touch the file again after
   upload, or wait for the cache TTL. Static assets cached in a browser are a
   separate problem — check the response `Cache-Control` header before blaming FTP.

## 4. Chinese / non-ASCII text becomes garbage after deploy

**Symptom** — the page renders `æµ‹è¯•` instead of `测试`, or PHP says
`syntax error, unexpected identifier`.

**Cause** — the file was re-encoded on the way out. Two usual suspects: a Windows
editor saving as GBK/ANSI, or a PowerShell one-liner that reads UTF-8 and writes it
back as ANSI (or double-encodes it).

**Fix**

- Write files as UTF-8 **without BOM**, and verify:

  ```powershell
  $b = [IO.File]::ReadAllBytes('file.php')
  "{0:X2} {1:X2} {2:X2}" -f $b[0], $b[1], $b[2]   # must NOT be EF BB BF
  ```

- When generating file content from PowerShell, always state the encoding:

  ```powershell
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
  ```

- Treat mojibake as data corruption: rewrite the file from a clean source rather than
  patching the broken text.

## 5. `Array.Contains()` returns False for text you can see on screen

**Symptom** — `curl.exe` output clearly contains the string, but
`$out.Contains('needle')` is `False`.

**Cause** — in PowerShell, native command output is an **array of lines**, and
`Contains` on an array compares whole elements, not substrings.

**Fix**

```powershell
$text = (& curl.exe -s https://example.com/js/app.js) -join "`n"
$text.Contains('needle')
```

## 6. Deleting a remote file

An FTP delete is a control-channel command, not an upload:

```powershell
curl.exe -sS --user "$env:FTP_USER:$env:FTP_PASS" ftp://ftp.example.com:21/ `
         -Q "DELE /public/api/stream.php" -o NUL -w "%{http_code}"
```

`226` means deleted. `550` means the path is wrong or already gone — verify with a
directory listing before assuming the script failed.

## 7. The deploy is "slow" or times out on a single big file

Shared hosts throttle per-connection throughput and may drop long transfers. Split
the work: upload code files every deploy, and treat large media as a separate,
resumable operation rather than part of the release. `-Retries` exists for transient
drops, not for pushing a 500 MB file through a 30-second window.

## 8. Post-deploy check returns 302 for a page you expect to be public

Not a deploy failure: the page is behind a login and redirects to `/login.php`. Check
the redirect target explicitly:

```powershell
curl.exe -s -o NUL -w "%{http_code} -> %{redirect_url}" https://example.com/pages/app.php
```

Expect `302 -> .../login.php` for authenticated pages, and `200` for public assets
(`/js/*.js`, `/css/*.css`).
