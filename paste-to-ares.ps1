<#
.SYNOPSIS
  Put the Windows clipboard image on a remote host and copy the remote path
  to your clipboard, so you can paste it into Claude Code over SSH.

.EXAMPLE
  .\paste-to-ares.ps1
  # Screenshot (Win+Shift+S) -> run this -> Ctrl+V in your Claude pane.

.NOTES
  Lives on WINDOWS. Bind to a hotkey; do NOT wire into ssh_config LocalCommand
  (that fires once per connection, not once per paste).

  Reads the clipboard via GDI+ rather than through WSL, so WSLg's clipboard
  translation is out of the picture entirely.

  /tmp on the remote is tmpfs: RAM-backed, gone on reboot, never hits disk.
#>
param(
  [string]$RemoteHost   = 'ares.evilsoft',
  [string]$User         = 'devon',
  [string]$Dir          = '/tmp',
  [int]$Port            = 22,
  # Matches the -i on the Windows Terminal ssh command. Explicit so this
  # works without any entry in C:\Users\devon\.ssh\config.
  [string]$IdentityFile = 'C:/Users/devon/.ssh/id_rsa',
  # Print the remote path to stdout and leave the clipboard alone.
  # Used by the Ctrl+V hotkey so the image stays on your clipboard.
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$local = $null
$name  = $null

if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
    # Screenshot / Snipping Tool / copied-from-browser
    $name  = "clip-$stamp.png"
    $local = Join-Path $env:TEMP $name
    $img   = [System.Windows.Forms.Clipboard]::GetImage()
    $img.Save($local, [System.Drawing.Imaging.ImageFormat]::Png)
    $img.Dispose()
}
elseif ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
    # Image file copied in Explorer -- ship the original bytes, no re-encode,
    # which also sidesteps GetImage()'s alpha flattening.
    $src   = [System.Windows.Forms.Clipboard]::GetFileDropList()[0]
    $name  = "clip-$stamp$([System.IO.Path]::GetExtension($src))"
    $local = Join-Path $env:TEMP $name
    Copy-Item -LiteralPath $src -Destination $local -Force
}
else {
    Write-Host 'No image on the clipboard. Take a screenshot (Win+Shift+S) first.' -ForegroundColor Yellow
    exit 1
}

$remotePath = "$Dir/$name"

# scp takes -P for port; ssh takes -p.
# BatchMode=yes makes a missing/rejected key fail fast instead of hanging on a
# password prompt you'd never see (the hotkey runs the window hidden).
& scp -q -P $Port -i $IdentityFile -o BatchMode=yes `
    $local ("{0}@{1}:{2}" -f $User, $RemoteHost, $remotePath)
$rc = $LASTEXITCODE
Remove-Item $local -Force -ErrorAction SilentlyContinue

if ($rc -ne 0) {
    Write-Host "scp failed (exit $rc)." -ForegroundColor Red
    exit $rc
}

if ($Quiet) {
    # stdout only -- caller handles insertion, clipboard untouched
    [Console]::Out.Write($remotePath)
} else {
    Set-Clipboard -Value $remotePath
    Write-Host "-> $remotePath  (path copied to clipboard)" -ForegroundColor Green
}
