#Requires AutoHotkey v2.0
#SingleInstance Force
;
; Diagnostic. Focus a Windows Terminal tab and press Ctrl+Alt+P.
; Dumps everything externally detectable about that window, and copies the
; report to the clipboard so it can be pasted somewhere useful.
;
; Run it once in the remote tab and once in a WSL tab, then compare: anything
; that differs between the two is a candidate discriminator.

^!p:: {
    hwnd  := WinGetID("A")
    out   := "=== active window ===`n"
    out .= "title:   " WinGetTitle(hwnd) "`n"
    out .= "class:   " WinGetClass(hwnd) "`n"
    out .= "exe:     " WinGetProcessName(hwnd) "`n"
    out .= "path:    " WinGetProcessPath(hwnd) "`n"
    pid   := WinGetPID(hwnd)
    out .= "pid:     " pid "`n"

    ; Windows Terminal keeps a per-tab title distinct from the window title
    ; when suppressApplicationTitle is off; both are worth seeing.
    try out .= "text:    " WinGetText(hwnd) "`n"

    out .= "`n=== descendant processes ===`n"
    out .= ProcessTree(pid)

    A_Clipboard := out
    MsgBox out, "WT probe (copied to clipboard)"
}

ProcessTree(rootPid) {
    static wmi := ComObjGet("winmgmts:\\.\root\cimv2")
    kids := Map(), info := Map()

    for p in wmi.ExecQuery("SELECT ProcessId,ParentProcessId,Name,CommandLine FROM Win32_Process") {
        info[p.ProcessId] := { name: p.Name, cmd: p.CommandLine ? p.CommandLine : "" }
        if !kids.Has(p.ParentProcessId)
            kids[p.ParentProcessId] := []
        kids[p.ParentProcessId].Push(p.ProcessId)
    }

    return Walk(rootPid, 0)

    Walk(pid, depth) {
        s := ""
        if !kids.Has(pid)
            return s
        for child in kids[pid] {
            i := info[child]
            ; Command lines are the interesting part -- an ssh invocation names
            ; the remote host outright.
            cmd := StrLen(i.cmd) > 160 ? SubStr(i.cmd, 1, 160) "..." : i.cmd
            s .= Format("{1}[{2}] {3}`n", StrRepeat("  ", depth + 1), child, i.name)
            if cmd
                s .= Format("{1}     {2}`n", StrRepeat("  ", depth + 1), cmd)
            s .= Walk(child, depth + 1)
        }
        return s
    }
}

StrRepeat(s, n) {
    out := ""
    loop n
        out .= s
    return out
}
