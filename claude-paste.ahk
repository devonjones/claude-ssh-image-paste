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

; Only hijack Ctrl+V in terminal windows whose title contains this substring.
; Leave it empty and EVERY Windows Terminal window is intercepted -- which is
; wrong if you also use local WSL or PowerShell tabs, where a Windows path is
; the correct thing to paste.
;
; Pin the title in that profile's Windows Terminal settings so it can't drift:
;     "tabTitle": "ares", "suppressApplicationTitle": true
; then:  setx CLIP_TITLE_MATCH ares
global TITLE_MATCH := EnvGet("CLIP_TITLE_MATCH")

SetTitleMatchMode 2

InRemoteTerminal() {
    global TITLE_MATCH
    if !WinActive("ahk_exe WindowsTerminal.exe")
        return false
    return TITLE_MATCH = "" || InStr(WinGetTitle("A"), TITLE_MATCH)
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

#HotIf InRemoteTerminal()

; '$' forces the keyboard hook so our own Send "^v" can't re-trigger this.
$^v:: {
    global SCRIPT

    if !ClipboardIsUploadable() {
        Send "^v"
        return
    }

    try {
        exec := ComObject("WScript.Shell").Exec(
            ; -ExecutionPolicy Bypass: the .ps1 is unsigned, and a re-download
            ; can re-apply a mark-of-the-web tag that RemoteSigned rejects.
            Format('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Quiet', SCRIPT))
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
