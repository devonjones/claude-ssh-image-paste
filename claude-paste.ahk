#Requires AutoHotkey v2.0
#SingleInstance Force

; Ctrl+V in Windows Terminal:
;   - real image on the clipboard  -> upload to ares, type the remote path
;   - anything else                -> ordinary paste, untouched
;
; Windows Terminal can't do this itself; its keybindings only trigger built-in
; actions, with no way to shell out. Hence AHK.

global SCRIPT := "C:\Users\YOU\paste-to-ares.ps1"   ; <-- set this

; True only for actual bitmap data (CF_DIB / CF_BITMAP / CF_DIBV5).
; CF_HDROP is deliberately excluded: copying a file in Explorer and hitting
; Ctrl+V should still paste its path, which is what you usually want.
HasClipboardImage() {
    return DllCall("IsClipboardFormatAvailable", "UInt", 8)
        || DllCall("IsClipboardFormatAvailable", "UInt", 2)
        || DllCall("IsClipboardFormatAvailable", "UInt", 17)
}

#HotIf WinActive("ahk_exe WindowsTerminal.exe")

; '$' forces the keyboard hook so our own Send "^v" can't re-trigger this.
$^v:: {
    global SCRIPT

    if !HasClipboardImage() {
        Send "^v"
        return
    }

    try {
        exec := ComObject("WScript.Shell").Exec(
            ; -ExecutionPolicy Bypass: this box is AllSigned, and the .ps1 isn't
            ; signed. Per-invocation only -- changes no system policy.
            Format('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Quiet', SCRIPT))
        ; ReadAll blocks until the upload finishes -- that's our wait.
        path := Trim(exec.StdOut.ReadAll(), " `t`r`n")
        code := exec.ExitCode
    } catch as e {
        MsgBox "Couldn't launch the uploader:`n`n" e.Message
        return
    }

    if (code != 0 || path = "") {
        MsgBox "Upload failed (exit " code "). Run paste-to-ares.ps1 by hand to see why."
        return
    }

    ; Type the path rather than pasting it, so the image stays on your clipboard.
    SendText path
}

#HotIf
