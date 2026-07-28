<#
.SYNOPSIS
  Put whatever is on the Windows clipboard -- a screenshot or copied files --
  onto a remote host, and hand back the remote path(s) so they can be pasted
  into Claude Code (or any CLI tool) running over SSH.

.DESCRIPTION
  Two clipboard shapes are handled:

    bitmap data (Win+Shift+S, Snipping Tool, "copy image" in a browser)
        -> written to a real PNG via GDI+, uploaded as <Dir>/clip-<stamp>.png

    copied files (Ctrl+C in Explorer)
        -> uploaded verbatim into <Dir>/clip-<stamp>/, original names kept

  By default the remote path is placed on your clipboard. With -Quiet the path
  goes to stdout and the clipboard is left alone -- the mode claude-paste.ahk
  uses, so your screenshot survives the paste.

.EXAMPLE
  .\clip-to-remote.ps1 -RemoteHost dev.example.com -User alice

.NOTES
  Configure once via environment variables and this file never needs editing:
    setx CLIP_REMOTE_HOST dev.example.com
    setx CLIP_REMOTE_USER alice
#>
param(
  [string]$RemoteHost   = $(if ($env:CLIP_REMOTE_HOST) { $env:CLIP_REMOTE_HOST } else { 'REMOTE_HOST' }),
  [string]$User         = $(if ($env:CLIP_REMOTE_USER) { $env:CLIP_REMOTE_USER } else { 'REMOTE_USER' }),

  # tmpfs on most Linux distributions: RAM-backed, cleared at reboot.
  [string]$Dir          = $(if ($env:CLIP_REMOTE_DIR)  { $env:CLIP_REMOTE_DIR }  else { '/tmp' }),
  [int]$Port            = 22,

  # Passed to scp explicitly, so this works with no ssh_config entry.
  [string]$IdentityFile = $(if ($env:CLIP_IDENTITY_FILE) { $env:CLIP_IDENTITY_FILE } else { "$env:USERPROFILE/.ssh/id_rsa" }),

  # Refuse anything larger than this in total. Guards against pasting a
  # 4 GB ISO into a terminal by accident.
  [int]$MaxMB           = 100,

  # Print remote path(s) to stdout, leave the clipboard untouched.
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Fail($msg) {
    Write-Host $msg -ForegroundColor Red
    exit 1
}

if ($RemoteHost -eq 'REMOTE_HOST' -or $User -eq 'REMOTE_USER') {
    Fail 'Not configured. Set CLIP_REMOTE_HOST and CLIP_REMOTE_USER, or pass -RemoteHost / -User.'
}

$sshBase = @('-o', 'BatchMode=yes', '-i', $IdentityFile)
$target  = "{0}@{1}" -f $User, $RemoteHost
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$cleanup = @()
$remote  = @()

if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
    # ---- bitmap on the clipboard: encode to PNG and send one file ----
    $name  = "clip-$stamp.png"
    $local = Join-Path $env:TEMP $name
    $img   = [System.Windows.Forms.Clipboard]::GetImage()
    $img.Save($local, [System.Drawing.Imaging.ImageFormat]::Png)
    $img.Dispose()

    $cleanup = @($local)
    $dest    = "$Dir/$name"
    $remote  = @($dest)

    & scp -q -P $Port @sshBase $local "${target}:${dest}"
    if ($LASTEXITCODE -ne 0) { Remove-Item $cleanup -Force -EA SilentlyContinue; Fail "scp failed (exit $LASTEXITCODE)." }
}
elseif ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
    # ---- files copied in Explorer: send verbatim, keep their names ----
    $dropped = @([System.Windows.Forms.Clipboard]::GetFileDropList())

    # Directories would need scp -r and can be arbitrarily large; skip loudly.
    $dirs  = @($dropped | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    $files = @($dropped | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })

    foreach ($d in $dirs) {
        Write-Host "skipping directory: $d" -ForegroundColor Yellow
    }
    if ($files.Count -eq 0) { Fail 'Nothing to upload (directories are not supported).' }

    $totalMB = [math]::Round((($files | ForEach-Object { (Get-Item -LiteralPath $_).Length }) | Measure-Object -Sum).Sum / 1MB, 1)
    if ($totalMB -gt $MaxMB) {
        Fail "Refusing to upload $totalMB MB (limit $MaxMB MB). Raise it with -MaxMB if you meant it."
    }

    # One subdirectory per paste: preserves original filenames without
    # collisions, and keeps a multi-file paste grouped together.
    $rdir   = "$Dir/clip-$stamp"
    $remote = $files | ForEach-Object { "$rdir/" + [System.IO.Path]::GetFileName($_) }

    & ssh -p $Port @sshBase $target "mkdir -p '$rdir'"
    if ($LASTEXITCODE -ne 0) { Fail "ssh mkdir failed (exit $LASTEXITCODE)." }

    & scp -q -P $Port @sshBase @files "${target}:${rdir}/"
    if ($LASTEXITCODE -ne 0) { Fail "scp failed (exit $LASTEXITCODE)." }
}
else {
    Write-Host 'Clipboard holds no image and no files.' -ForegroundColor Yellow
    exit 1
}

if ($cleanup) { Remove-Item $cleanup -Force -EA SilentlyContinue }

$joined = $remote -join ' '

if ($Quiet) {
    # stdout only -- caller handles insertion, clipboard untouched
    [Console]::Out.Write($joined)
} else {
    Set-Clipboard -Value $joined
    Write-Host "-> $joined  (copied to clipboard)" -ForegroundColor Green
}
