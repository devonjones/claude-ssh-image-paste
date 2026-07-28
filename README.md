# claude-ssh-image-paste

Paste screenshots and files into a Claude Code session running over SSH.

Ctrl+V in Windows Terminal uploads whatever is on your clipboard to the remote
host and types the resulting path into the prompt. Text pastes are untouched.

```
Win+Shift+S  ->  Ctrl+V  ->  /tmp/clip-20260728-171743.png
Ctrl+C a file in Explorer  ->  Ctrl+V  ->  /tmp/clip-20260728-172210/wolf-head.svg
```

## The problem

Claude Code reads the clipboard of the machine it runs on. Over SSH that's the
remote host, which has no clipboard and no access to yours. SSH carries no
channel for image data either — the only clipboard escape sequence terminals
implement, OSC 52, is text-only.

tmux is not involved in this limitation. Reordering `ssh` and `tmux` changes
nothing, because Claude Code stays on the far side of the SSH boundary either
way. There are exactly two fixes: carry the bytes across yourself, or move
Claude Code onto the machine holding the clipboard. This is the first.

## How it works

```
Win+Shift+S, or Ctrl+C on a file
   |                            content lands on the Windows clipboard
Ctrl+V in Windows Terminal
   |
claude-paste.ahk                intercepts, inspects the clipboard FORMAT
   |                              not image/files -> ordinary paste, done
   |                              otherwise       -> continue
clip-to-remote.ps1              bitmap -> GDI+ encodes a real PNG
   |                            files  -> sent verbatim, names preserved
   |                            scp to the remote host, path printed
   |
claude-paste.ahk                types the path(s) into the terminal
   |
Claude Code                     reads them as ordinary files
```

The AHK script waits on the PowerShell process by blocking on its stdout, so a
path is never typed before its upload finishes.

## Requirements

- Windows with [AutoHotkey **v2**](https://www.autohotkey.com/) (v1 will not run these)
- OpenSSH client on Windows (`ssh`/`scp` on PATH — ships with Windows 10/11)
- Key-based SSH auth already working to the remote host
- A Linux/macOS remote

## Install

Put both files in the same folder, anywhere:

```
clip-to-remote.ps1
claude-paste.ahk
```

Configure once, via environment variables — no file editing, so re-downloading
never clobbers your settings:

```powershell
setx CLIP_REMOTE_HOST dev.example.com
setx CLIP_REMOTE_USER alice
```

Optional: `CLIP_REMOTE_DIR` (default `/tmp`), `CLIP_IDENTITY_FILE` (default
`%USERPROFILE%/.ssh/id_rsa`), `CLIP_SCRIPT` (if you keep the two files apart).

### Scope it to the right terminal

By default **every** Windows Terminal window is intercepted. If you also use
local WSL or PowerShell tabs, that's wrong there — a Windows path is exactly
what you want to paste locally, and uploading it to a remote host isn't.

There is no way to ask Windows Terminal what's running in the focused tab. Every
tab in a window shares one `WindowsTerminal.exe` process, and the console host
and the shell appear as flat siblings in the process tree — so you can see which
sessions exist, but never which one has focus. Profile icons don't help either;
they're rendered internally and aren't exposed to other programs.

The window title is the only per-tab signal. Pin it in each remote profile's
Windows Terminal settings, since a shell (tmux especially) will otherwise
overwrite it with something identical everywhere:

```json
"tabTitle": "devbox",
"suppressApplicationTitle": true
```

Then map titles to targets — semicolon-separated, first match wins:

```powershell
setx CLIP_HOSTS "devbox=alice@devbox.example.com;build=root@10.0.0.9"
```

Ctrl+V now uploads to whichever host that tab belongs to. Titles matching
nothing — local WSL, PowerShell — paste normally. Matching is on substrings, so
`"tabTitle": "devbox — prod"` still matches `devbox`.

With `CLIP_HOSTS` unset, every Windows Terminal window is intercepted and
`CLIP_REMOTE_HOST`/`CLIP_REMOTE_USER` are used — fine if you only ever SSH from
Windows Terminal, wrong the moment you open a local shell in it.

If the files came from the internet, clear the mark-of-the-web tag or
PowerShell will refuse to run the script:

```powershell
Unblock-File -Path .\clip-to-remote.ps1
```

Then double-click `claude-paste.ahk`. A green **H** appears in the tray. To
start it at login, put a shortcut in `shell:startup` (Win+R → `shell:startup`).

## Usage

| Keystroke | Clipboard holds | Result |
|---|---|---|
| Ctrl+V | a screenshot | uploaded as `<dir>/clip-<stamp>.png`, path typed |
| Ctrl+V | file(s) from Explorer | uploaded into `<dir>/clip-<stamp>/`, paths typed |
| Ctrl+V | text | ordinary paste |
| Ctrl+Shift+V | anything | ordinary paste, always — bypasses all of this |

The script can also be run directly, which puts the path on your clipboard
instead of typing it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\clip-to-remote.ps1
```

## Design notes

**Uploads land in `/tmp` by default.** On most Linux distributions that's
tmpfs — RAM-backed, so pasted content never touches disk and is gone at reboot.
`systemd-tmpfiles` also sweeps it on a timer. The point is to leave nothing
behind; set `CLIP_REMOTE_DIR` if you want uploads kept.

**Clipboard is read through GDI+ in PowerShell, not via WSL.** That keeps
WSLg's clipboard translation entirely out of the path, and means no dependence
on WSL2 localhost forwarding. WSL is never involved.

**Paths are typed, not pasted.** `SendText` leaves your clipboard intact, so
Ctrl+V into Claude and then Ctrl+V into Slack both do the right thing. This is
why the `.ps1` has `-Quiet`: it prints to stdout instead of calling
`Set-Clipboard`.

**Copied files are uploaded rather than pasted as Windows paths.** A
`C:\Users\...` path means nothing in a shell on another machine. Ctrl+Shift+V
exists for the rare case where you want the literal string.

**Multi-file pastes get their own subdirectory.** Original filenames are
preserved without collisions, and a group of files stays grouped. Directories
are skipped rather than recursed — `scp -r` on an unbounded tree is not
something a keystroke should do. Total upload size is capped at 100 MB
(`-MaxMB` to change).

**`-o BatchMode=yes` on ssh/scp.** The hotkey runs PowerShell hidden. Without
it, a rejected key would sit forever on an invisible password prompt instead of
failing fast.

**`-ExecutionPolicy Bypass` in the launcher.** Unsigned scripts that carry a
mark-of-the-web tag are rejected under the default `RemoteSigned` policy, with
a confusing "is not digitally signed" error. `Unblock-File` clears the tag; the
flag means a future re-download can't silently break the hotkey.

**The AHK script finds the `.ps1` via `A_ScriptDir`.** Keep them together and
there is no path to configure and nothing to re-edit after an update.

**No `LocalCommand` in ssh_config, and no clipboard watcher.** `LocalCommand`
fires once per connection, not once per paste, and would spawn a duplicate for
every terminal opened. A watcher that auto-uploads on copy is worse: it hijacks
the clipboard for things copied for unrelated reasons. Explicit invocation on
Ctrl+V is the correct model.

## Alternatives considered

- **A different terminal emulator.** None forward image clipboard data over
  SSH. WezTerm, Kitty, Ghostty and Alacritty all behave identically here.
- **VS Code Remote-SSH.** Doesn't work natively; needs an add-on extension, and
  the mature ones are macOS-first. Those extensions also write a remote temp
  file and inject its path — the same mechanism, just hidden. Costs tmux
  keybindings (Ctrl+B/K/W collide) for no real gain.
- **An MCP server returning image content blocks.** The only genuinely
  zero-file design: MCP tool results support
  `{"type":"image","data":"<base64>","mimeType":"image/png"}`, so an image
  could enter the conversation with nothing written anywhere. Rejected because
  `/tmp` being tmpfs made the file question moot, and it can't carry arbitrary
  file types the way this can.
- **Running Claude Code locally against the remote over sshfs.** Ctrl+V would
  work natively, but it trades filesystem performance and on-host tooling for
  a paste shortcut.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Ctrl+V does nothing unusual | AHK not running, elevation mismatch (if Windows Terminal runs elevated, AHK must too), or the tab title matches no `CLIP_HOSTS` entry |
| Uploads fire in local WSL/PowerShell tabs | `CLIP_HOSTS` unset — see [Scope it to the right terminal](#scope-it-to-the-right-terminal) |
| "Upload failed (exit 1)" | Run the `.ps1` by hand to see the real error |
| "is not digitally signed" | Mark-of-the-web tag; `Unblock-File` the script |
| "Not configured" | `CLIP_REMOTE_HOST` / `CLIP_REMOTE_USER` unset — `setx` needs a new shell to take effect |
| Hangs, then fails | Key auth isn't working; `BatchMode` should surface this fast |
| Path appears but can't be read | Confirm it arrived: `ls -la /tmp/clip-*` on the remote |
| Hostname stops resolving | VPN overriding DNS — pass `-RemoteHost <ip>` |

## License

MIT
