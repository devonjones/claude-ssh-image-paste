# Pasting images into Claude Code over SSH

Ctrl+V in Windows Terminal puts a screenshot into a Claude Code session running
on `ares`. Text pastes are unaffected.

## The problem

Claude Code reads the clipboard of the machine it runs on. Over SSH that's
`ares`, which has no clipboard and no access to yours. SSH carries no channel
for image data either — the only clipboard escape sequence terminals implement,
OSC 52, is text-only.

tmux is not involved in this limitation. Reordering `ssh` and `tmux` changes
nothing, because Claude Code stays on the far side of the SSH boundary either
way. There are exactly two fixes: carry the bytes across yourself, or move
Claude Code onto the machine holding the clipboard. This is the first.

## How it works

```
Win+Shift+S                 image lands on the Windows clipboard
   |
Ctrl+V in Windows Terminal
   |
claude-paste.ahk            intercepts, checks the clipboard FORMAT
   |                          not a bitmap -> ordinary paste, done
   |                          bitmap      -> continue
paste-to-ares.ps1           reads clipboard via GDI+, writes a real PNG,
   |                          scp's it to ares, prints the remote path
   |
claude-paste.ahk            types that path into the terminal
   |
Claude Code                 reads /tmp/clip-<stamp>.png as an image
```

The AHK script waits on the PowerShell process by blocking on its stdout, so
the path is never typed before the upload finishes.

## The files

| File | Lives on | Purpose |
|---|---|---|
| `paste-to-ares.ps1` | Windows (`C:\Users\devon`) | Clipboard → PNG → scp → prints path |
| `claude-paste.ahk` | Windows (`C:\Users\devon`) | Ctrl+V interception and branching |

Masters live in `~/bin` on ares. The Windows copies are what actually run.

## Setup from scratch

```powershell
scp -i "C:/Users/devon/.ssh/id_rsa" devon@ares.evilsoft:bin/paste-to-ares.ps1 $HOME\
scp -i "C:/Users/devon/.ssh/id_rsa" devon@ares.evilsoft:bin/claude-paste.ahk   $HOME\
Unblock-File -Path C:\Users\devon\paste-to-ares.ps1, C:\Users\devon\claude-paste.ahk
```

Then edit line 12 of `claude-paste.ahk`:

```autohotkey
global SCRIPT := "C:\Users\devon\paste-to-ares.ps1"
```

Double-click the `.ahk`. A green **H** appears in the tray. For it to survive
reboots, drop a shortcut in `shell:startup` (Win+R → `shell:startup`).

**Every re-pull overwrites line 12.** Reset it and restart the script
(tray icon → Exit, then double-click again).

Nothing goes in `~/.ssh/config`. This reuses the key auth already working for
your Windows Terminal profile.

## Why the pieces are what they are

**`/tmp` on ares, not a real directory.** `/tmp` is tmpfs — 14 GB, RAM-backed,
so pasted images never touch disk and vanish at reboot. A `systemd-tmpfiles`
timer also sweeps it daily with a 10-day age policy, so long uptimes don't
accumulate either.

**Clipboard read via GDI+ in PowerShell, not `wl-paste` in WSL.** Keeps WSLg's
clipboard translation entirely out of the path. WSL is never involved, which
also means no dependence on WSL2 localhost forwarding.

**Typing the path (`SendText`) rather than round-tripping the clipboard.** Your
image stays on the clipboard after pasting. Ctrl+V into Claude then Ctrl+V into
Slack both do the right thing. This is why the `.ps1` has a `-Quiet` switch: it
prints the path to stdout instead of calling `Set-Clipboard`.

**Only real bitmap formats trigger the upload** — CF_DIB (8), CF_BITMAP (2),
CF_DIBV5 (17). CF_HDROP (15) is deliberately excluded so that copying a file in
Explorer and hitting Ctrl+V still pastes its path, which is usually what you
want. Run the `.ps1` by hand for those; it handles Explorer-copied image files
by shipping the original bytes with no re-encode.

**`-o BatchMode=yes` on scp.** The hotkey runs PowerShell hidden. Without this,
a rejected key would sit forever on an invisible password prompt instead of
failing fast.

**`-ExecutionPolicy Bypass` in the launcher.** This box is `RemoteSigned` at
LocalMachine scope, with no GPO. Files can arrive carrying a mark-of-the-web
tag, which RemoteSigned rejects with a confusing "is not digitally signed"
error. `Unblock-File` clears it; the Bypass flag means a future re-pull that
re-marks the file can't break the hotkey.

**No `LocalCommand` in ssh_config, and no clipboard watcher.** `LocalCommand`
fires once per connection, not once per paste, and would spawn a duplicate for
every terminal opened to ares. A watcher that auto-uploads on copy is worse
still: it hijacks the clipboard for images copied for unrelated reasons.
Explicit invocation on Ctrl+V is the correct model.

## Approaches considered and rejected

- **A different terminal emulator.** None forward image clipboard data over
  SSH. WezTerm, Kitty, Ghostty, Alacritty all behave identically here.
- **VS Code Remote-SSH.** Doesn't work natively; needs an add-on extension, and
  the mature ones are macOS-first. Those extensions also write a remote temp
  file and inject the path — the same mechanism, just hidden. Costs tmux
  keybindings (Ctrl+B/K/W collide) for no gain.
- **An MCP server returning image content blocks.** The only genuinely
  zero-file design — MCP tool results support
  `{"type":"image","data":"<base64>","mimeType":"image/png"}`, so the image
  would enter the conversation with nothing written anywhere. Rejected only
  because `/tmp` being tmpfs made the file question moot. Worth revisiting if
  the path-pasting ever becomes annoying.
- **Claude Code local in WSL against ares over sshfs.** Would make Ctrl+V work
  natively, but trades filesystem performance and on-host tooling for it.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Ctrl+V does nothing unusual | AHK not running, or elevation mismatch — if Windows Terminal runs as admin, AHK must too |
| "Upload failed (exit 1)" | Run the `.ps1` by hand (below) to see the real error |
| "is not digitally signed" | Mark-of-the-web tag; `Unblock-File` the script |
| Hangs a few seconds, then fails | Key auth not working; `BatchMode` should make this fail fast instead |
| Path types but Claude can't read it | Check the file actually arrived: `ls -la /tmp/clip-*.png` on ares |
| Works, but `ares.evilsoft` stops resolving | VPN overriding router DNS — pass `-RemoteHost 10.5.2.12` |

Run it visibly to see real errors (image on the clipboard first):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\devon\paste-to-ares.ps1"
```

Without `-Quiet` it sets the clipboard to the path and prints what it did, so
this doubles as a working manual fallback if AHK is ever unavailable.

## Environment specifics

- `ares.evilsoft` → `10.5.2.12`, resolved by the UniFi router (not a hosts file)
- Key: `C:/Users/devon/.ssh/id_rsa`, passed explicitly with `-i`
- Windows Terminal launches `ssh.exe` directly, no `Host` entry in ssh_config
- AutoHotkey **v2** — the script uses v2 syntax and will not run under v1
- Backslashes are literal in AHK strings; it escapes with a backtick
