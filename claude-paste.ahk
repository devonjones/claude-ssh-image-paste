#Requires AutoHotkey v2.0
#SingleInstance Force

; Ctrl+V in Windows Terminal:
;   image or files on the clipboard -> upload, then type the remote path(s)
;   anything else                   -> ordinary paste, untouched
;
; Ctrl+Shift+V always does a plain local paste, bypassing all of this.
;
; Windows Terminal can't do this itself; its keybindings only trigger built-in
; actions, with no way to shell out. Hence AutoHotkey.

; Found next to this script, so re-downloading either file never breaks the
; wiring. Override with CLIP_SCRIPT if you keep them apart.
global SCRIPT := EnvGet("CLIP_SCRIPT") || A_ScriptDir "\clip-to-remote.ps1"

; Which terminal tabs are remote, and which host each one is.
;
; Windows Terminal gives no way to ask what's running in the focused tab: every
; tab shares one process, and the console host and shell are flat siblings in
; the process tree. The window title is the only per-tab signal, and tmux sets
; it to "tmux" everywhere, so it has to be pinned per profile:
;
;     "tabTitle": "devbox", "suppressApplicationTitle": true
;
; Then map those titles to targets. Semicolon-separated, first match wins:
;
;     setx CLIP_HOSTS "devbox=alice@devbox.example.com;build=root@10.0.0.9"
;
; Titles that match nothing -- local WSL, PowerShell -- paste normally.
; With CLIP_HOSTS unset, falls back to CLIP_REMOTE_HOST/CLIP_REMOTE_USER for
; every Windows Terminal window.
global HOST_MAP := ParseHosts(EnvGet("CLIP_HOSTS"))

SetTitleMatchMode 2

ParseHosts(spec) {
    m := []
    for entry in StrSplit(spec, ";") {
        entry := Trim(entry)
        if (entry = "" || !InStr(entry, "="))
            continue
        parts := StrSplit(entry, "=", , 2)
        m.Push({ match: Trim(parts[1]), target: Trim(parts[2]) })
    }
    return m
}

; Returns "" when this window isn't a remote terminal, otherwise the scp
; target ("user@host", or "-" meaning fall back to the script's own defaults).
RemoteTarget() {
    global HOST_MAP
    if !WinActive("ahk_exe WindowsTerminal.exe")
        return ""
    if !HOST_MAP.Length
        return "-"
    title := WinGetTitle("A")
    for h in HOST_MAP
        if InStr(title, h.match)
            return h.target
    return ""
}

if !FileExist(SCRIPT) {
    MsgBox "Can't find the uploader:`n`n" SCRIPT "`n`nKeep it beside this script, or set CLIP_SCRIPT."
    ExitApp
}

; CF_DIB (8), CF_BITMAP (2), CF_DIBV5 (17)  -> a real bitmap
; CF_HDROP (15)                             -> files copied in Explorer
;
; HDROP is included because this terminal is always remote: a Windows path
; pasted into a shell on another machine is never the useful answer.
; Ctrl+Shift+V is the escape hatch when you really do want the literal path.
ClipboardIsUploadable() {
    for fmt in [8, 2, 17, 15]
        if DllCall("IsClipboardFormatAvailable", "UInt", fmt)
            return true
    return false
}

#HotIf RemoteTarget() != ""

; '$' forces the keyboard hook so our own Send "^v" can't re-trigger this.
$^v:: {
    global SCRIPT

    if !ClipboardIsUploadable() {
        Send "^v"
        return
    }

    ; Send to whichever host this tab is, not a single hardcoded one.
    args := ""
    target := RemoteTarget()
    if (target != "-") {
        if InStr(target, "@") {
            p := StrSplit(target, "@", , 2)
            args := Format(' -User "{1}" -RemoteHost "{2}"', p[1], p[2])
        } else {
            args := Format(' -RemoteHost "{1}"', target)
        }
    }

    try {
        exec := ComObject("WScript.Shell").Exec(
            ; -ExecutionPolicy Bypass: the .ps1 is unsigned, and a re-download
            ; can re-apply a mark-of-the-web tag that RemoteSigned rejects.
            Format('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Quiet{2}', SCRIPT, args))
        ; ReadAll blocks until the upload finishes -- that's our wait.
        paths := Trim(exec.StdOut.ReadAll(), " `t`r`n")
        code  := exec.ExitCode
    } catch as e {
        MsgBox "Couldn't launch the uploader:`n`n" e.Message
        return
    }

    if (code != 0 || paths = "") {
        MsgBox "Upload failed (exit " code ").`n`nRun clip-to-remote.ps1 by hand to see why."
        return
    }

    ; Type the path rather than pasting it, so the clipboard survives intact.
    SendText paths
}

; Escape hatch: plain local paste, no upload, no interception.
$^+v:: Send "^v"

#HotIf
