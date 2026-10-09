; =====================================================================
; ahk-tiler - tiling window manager + status bar in ONE AutoHotkey v1.1
; script (Unicode build). ASCII-only on purpose: AHK v1 reads files
; without BOM as ANSI.
;
; Usage:  AutoHotkeyU64.exe tiler.ahk [--ini=path\to\file.ini] [--selftest]
; Config: tiler.ini (same folder). Panic key: Ctrl+Alt+Shift+Esc.
; =====================================================================

#NoEnv
#SingleInstance, Force
#Persistent
#KeyHistory, 0
SetBatchLines, -1
SetWinDelay, -1
SetKeyDelay, -1, -1
ListLines, Off

; Per-monitor DPI awareness. Must come before any window is created so
; every coordinate we read/write is in physical pixels.
if !DllCall("SetProcessDpiAwarenessContext", "Ptr", -4, "Ptr")
    DllCall("SetProcessDPIAware")

; NOTE: "global" at script level makes S a SUPER-GLOBAL (visible in every
; function) and AHK variable names are case-insensitive, so never use a
; variable named "s" anywhere: assigning it would overwrite S itself.
global S := {}
S.ini := A_ScriptDir "\tiler.ini"
Loop, %0%
{
    arg := %A_Index%
    if (SubStr(arg, 1, 6) = "--ini=")
        S.ini := SubStr(arg, 7)
    else if (arg = "--selftest")
        S.selftest := true
    else if (arg = "--quit")
        S.quitNow := true
}
Init()
return

HotkeyHandler:
    LogMsg("hotkey " A_ThisHotkey " -> " S.hk[A_ThisHotkey])
    DoAction(S.hk[A_ThisHotkey])
return

; ---------------------------------------------------------------------
; startup / shutdown
; ---------------------------------------------------------------------
Init() {
    global S
    S.dir := A_ScriptDir
    ; --quit: starting a new instance already makes the running one shut down
    ; cleanly (#SingleInstance Force); also un-hide anything a crash left behind
    if (S.quitNow) {
        RecoverHidden()
        ExitApp
    }
    LoadConfig()
    if (S.selftest) {
        SelfTest()
        ExitApp
    }
    S.hid := {}            ; hwnd -> 1 : windows we hid (inactive workspaces)
    S.loc := {}            ; hwnd -> {mon, ws}
    S.reject := {}         ; hwnd -> tick until which we skip re-checking
    S.exeCache := {}
    S.borderCache := {}
    S.noMove := {}         ; hwnd -> 1 : SetWindowPos failed (elevated, etc.)
    S.queue := []
    S.dirty := {}
    S.mons := []
    S.monByDev := {}
    S.monByHmon := {}
    S.focus := 0
    S.activeMon := ""
    S.paused := false
    S.fakeHide := ""
    S.cpu := 0
    S.ram := 0
    S.lastIdle := 0
    S.lastKern := 0
    S.lastUser := 0
    S.fnQueue := Func("ProcessQueue")
    S.fnTick := Func("Tick")
    S.fnReconcile := Func("Reconcile")
    S.fnDisplay := Func("HandleDisplayChange")
    S.fnWork := Func("RefreshWork")
    S.fnSave := Func("SaveHidden")
    S.fnCmd := Func("PollCmd")
    S.gdip := GdipStart()
    RecoverHidden()
    RebuildMonitors()
    Reconcile(true)
    ; adopt the window that already has focus (no event will announce it)
    fg := DllCall("GetForegroundWindow", "Ptr")
    if (fg && S.loc.HasKey(fg))
        OnForeground(fg)
    Flush()
    RegisterHooks()
    RegisterHotkeys()
    OnMessage(0x7E, "OnDisplayChange")
    OnMessage(0x1A, "OnSettingChange")
    OnMessage(0x201, "OnBarClick")
    OnExit("Cleanup")
    Arm(S.fnTick, 1000)
    Arm(S.fnReconcile, 2000)
    if (S.c.debug)
        Arm(S.fnCmd, 200)
    Tick()
    LogMsg("started pid=" DllCall("GetCurrentProcessId") " mons=" S.mons.Length())
}

; SetTimer with a function object. In AHK v1 "SetTimer, % S.fn, ..." (object
; property inline) misbehaves; going through a parameter is reliable.
Arm(f, period) {
    SetTimer, % f, % period
}

Cleanup(reason, code) {
    global S
    if S.exiting
        return 0
    S.exiting := true
    Arm(S.fnTick, "Off")
    Arm(S.fnReconcile, "Off")
    for i, h in S.hooks
        DllCall("UnhookWinEvent", "Ptr", h)
    for hwnd in S.hid.Clone()
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 8)
    for hwnd in S.loc
        SetBorder(hwnd, 0xFFFFFFFF)
    BarsDestroy()
    FileDelete, % S.dir "\hidden.txt"
    if S.gdip
        DllCall("gdiplus\GdiplusShutdown", "Ptr", S.gdip)
    return 0
}

RecoverHidden() {
    global S
    f := S.dir "\hidden.txt"
    if !FileExist(f)
        return
    FileRead, txt, %f%
    Loop, Parse, txt, `n, `r
    {
        if (A_LoopField = "")
            continue
        hw := A_LoopField + 0
        if DllCall("IsWindow", "Ptr", hw)
            DllCall("ShowWindow", "Ptr", hw, "Int", 8)
    }
    FileDelete, %f%
}

SaveHidden() {
    global S
    txt := ""
    for hw in S.hid
        txt .= hw "`n"
    f := FileOpen(S.dir "\hidden.txt", "w")
    if f {
        f.Write(txt)
        f.Close()
    }
}

LogMsg(msg) {
    global S
    if !S.c.debug
        return
    FileAppend, % A_Now " " msg "`n", % S.dir "\tiler.log"
}

; ---------------------------------------------------------------------
; config
; ---------------------------------------------------------------------
CfgInt(key, def, sec := "general") {
    global S
    IniRead, v, % S.ini, % sec, % key, % def
    return v + 0
}

CfgStr(key, def, sec := "general") {
    global S
    IniRead, v, % S.ini, % sec, % key, % def
    if (v = "ERROR")
        v := def
    return v
}

HexToInt(str) {
    str := Trim(str, "# `t")
    ; go through a variable: ("0x" str) + 0 does not convert in AHK v1
    num := "0x" . str
    return num + 0
}

; Windows COLORREF is 0x00BBGGRR
HexToColorRef(str) {
    v := HexToInt(str)
    r := (v >> 16) & 0xFF
    g := (v >> 8) & 0xFF
    b := v & 0xFF
    return (b << 16) | (g << 8) | r
}

LoadConfig() {
    global S
    c := {}
    c.padO := CfgInt("padding_outer", 6)
    c.padI := CfgInt("padding_inner", 6)
    c.wsCount := CfgInt("workspaces", 9)
    c.debug := CfgInt("debug", 0)
    c.testPrefix := CfgStr("test_title_prefix", "")
    c.adoptRules := CfgInt("apply_rules_on_start", 0)
    c.border := CfgInt("border", 1)
    c.borderFocus := HexToColorRef(CfgStr("border_focus", "8dbcff"))
    c.borderUnfocus := HexToColorRef(CfgStr("border_unfocus", "a1a1a1"))
    c.bar := CfgInt("enabled", 1, "bar")
    c.barPos := CfgStr("position", "top", "bar")
    c.barH := CfgInt("height", 28, "bar")
    c.barFont := CfgStr("font", "JetBrains Mono", "bar")
    c.barFontSize := CfgInt("font_size", 13, "bar")
    c.hideEmpty := CfgInt("hide_empty_workspaces", 1, "bar")
    c.right := CfgStr("right", "cpu,ram,battery,date,time", "bar")
    c.cBg := 0xFF000000 | HexToInt(CfgStr("color_bg", "1c2023", "bar"))
    c.cChip := 0xFF000000 | HexToInt(CfgStr("color_chip", "393f45", "bar"))
    c.cFg := 0xFF000000 | HexToInt(CfgStr("color_fg", "c7ccd1", "bar"))
    c.cDim := 0xFF000000 | HexToInt(CfgStr("color_dim", "747c84", "bar"))
    c.cAccent := 0xFF000000 | HexToInt(CfgStr("color_accent", "ae95c7", "bar"))
    c.ignore := ParseRules("ignore")
    c.float := ParseRules("float")
    c.rules := ParseRules("rules")
    S.c := c
}

; "kind:pattern=value" lines -> [{kind, pat, val}]
ParseRules(sec) {
    global S
    IniRead, txt, % S.ini, % sec
    rules := []
    if (txt = "ERROR")
        return rules
    Loop, Parse, txt, `n, `r
    {
        line := A_LoopField
        if (line = "" || SubStr(line, 1, 1) = ";")
            continue
        key := line
        val := ""
        if RegExMatch(line, "^(.*)=([^=]*)$", mm) {
            key := mm1
            val := mm2
        }
        q := InStr(key, ":")
        if !q
            continue
        rules.Push({kind: SubStr(key, 1, q - 1), pat: SubStr(key, q + 1), val: val})
    }
    return rules
}

RuleMatch(rule, exe, cls, title) {
    k := rule.kind
    p := rule.pat
    if (k = "exe")
        return (exe = p)
    if (k = "class")
        return (cls = p)
    if (k = "title")
        return InStr(title, p) ? true : false
    if (k = "titlere")
        return RegExMatch(title, p) ? true : false
    if (k = "classre")
        return RegExMatch(cls, p) ? true : false
    return false
}

AnyRule(rules, exe, cls, title) {
    for i, r in rules {
        if RuleMatch(r, exe, cls, title)
            return r
    }
    return ""
}

; ---------------------------------------------------------------------
; window inspection helpers
; ---------------------------------------------------------------------
GetStyle(hwnd) {
    return DllCall(A_PtrSize = 8 ? "GetWindowLongPtrW" : "GetWindowLongW", "Ptr", hwnd, "Int", -16, "UInt")
}

GetExStyle(hwnd) {
    return DllCall(A_PtrSize = 8 ? "GetWindowLongPtrW" : "GetWindowLongW", "Ptr", hwnd, "Int", -20, "UInt")
}

GetTitle(hwnd) {
    len := DllCall("GetWindowTextLengthW", "Ptr", hwnd)
    if !len
        return ""
    VarSetCapacity(buf, (len + 2) * 2, 0)
    DllCall("GetWindowTextW", "Ptr", hwnd, "Str", buf, "Int", len + 1)
    return buf
}

GetClass(hwnd) {
    VarSetCapacity(buf, 512, 0)
    DllCall("GetClassNameW", "Ptr", hwnd, "Str", buf, "Int", 256)
    return buf
}

GetExe(hwnd) {
    global S
    DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "UInt*", pid, "UInt")
    if S.exeCache.HasKey(pid)
        return S.exeCache[pid]
    exe := ""
    h := DllCall("OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr")
    if h {
        VarSetCapacity(buf, 1040, 0)
        n := 520
        if DllCall("QueryFullProcessImageNameW", "Ptr", h, "UInt", 0, "Str", buf, "UInt*", n)
            exe := RegExReplace(buf, ".*\\")
        DllCall("CloseHandle", "Ptr", h)
    }
    S.exeCache[pid] := exe
    return exe
}

GetPid(hwnd) {
    DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "UInt*", pid, "UInt")
    return pid
}

IsCloaked(hwnd) {
    c := 0
    DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14, "UInt*", c, "UInt", 4)
    return c
}

IsWin(hwnd) {
    return DllCall("IsWindow", "Ptr", hwnd) ? true : false
}

GetRoot(hwnd) {
    return DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr")
}

VisRect(hwnd) {
    VarSetCapacity(rc, 16, 0)
    if (DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 9, "Ptr", &rc, "UInt", 16) != 0)
        DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", &rc)
    return {l: NumGet(rc, 0, "Int"), t: NumGet(rc, 4, "Int"), r: NumGet(rc, 8, "Int"), b: NumGet(rc, 12, "Int")}
}

; Why a window is NOT tiled ("" = it is manageable). honorTest=false skips
; the test_title_prefix filter (used by the classify command).
ManageReason(hwnd, honorTest := true) {
    global S
    if !hwnd
        return "no handle"
    if !DllCall("IsWindow", "Ptr", hwnd)
        return "not a window"
    if !DllCall("IsWindowVisible", "Ptr", hwnd)
        return "invisible"
    if (GetRoot(hwnd) != hwnd)
        return "child window"
    if (DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr") != 0)
        return "owned window (dialog)"
    ex := GetExStyle(hwnd)
    if ((ex & 0x80) && !(ex & 0x40000))
        return "tool window"
    if (ex & 0x08000000)
        return "no-activate window"
    st := GetStyle(hwnd)
    if (st & 0x40000000)
        return "child style"
    if !(st & 0xC00000) && !(st & 0x40000)
        return "no caption/frame"
    if IsCloaked(hwnd)
        return "cloaked"
    if (GetPid(hwnd) = DllCall("GetCurrentProcessId"))
        return "own window"
    cls := GetClass(hwnd)
    if cls in Shell_TrayWnd,Shell_SecondaryTrayWnd,Progman,WorkerW,Windows.UI.Core.CoreWindow,XamlExplorerHostIslandWindow,NotifyIconOverflowWindow,TopLevelWindowForOverflowXamlIsland
        return "shell window"
    title := GetTitle(hwnd)
    if (title = "")
        return "no title"
    if (honorTest && S.c.testPrefix != "" && SubStr(title, 1, StrLen(S.c.testPrefix)) != S.c.testPrefix)
        return "outside test prefix"
    if !DllCall("IsIconic", "Ptr", hwnd) {
        r := VisRect(hwnd)
        if ((r.r - r.l) < 60 || (r.b - r.t) < 40)
            return "too small"
    }
    if AnyRule(S.c.ignore, GetExe(hwnd), cls, title)
        return "ignore rule"
    return ""
}

IsManageable(hwnd) {
    return (ManageReason(hwnd) = "")
}

; debug: dry-run over every real top-level window, nothing is moved
Classify() {
    global S
    out := ""
    WinGet, ids, List
    Loop, %ids%
    {
        hw := ids%A_Index%
        why := ManageReason(hw, false)
        verdict := (why = "") ? (IsFloatRule(hw) ? "FLOAT" : "TILE") : "skip: " why
        t := StrReplace(GetTitle(hw), "`n", " ")
        out .= verdict " | " GetExe(hw) " | " GetClass(hw) " | " t "`n"
    }
    f := FileOpen(S.dir "\tiler.classify", "w")
    f.Write(out)
    f.Close()
}

IsFloatRule(hwnd) {
    global S
    return AnyRule(S.c.float, GetExe(hwnd), GetClass(hwnd), GetTitle(hwnd)) ? true : false
}

RuleWorkspace(hwnd) {
    global S
    r := AnyRule(S.c.rules, GetExe(hwnd), GetClass(hwnd), GetTitle(hwnd))
    if r
        return r.val + 0
    return 0
}

SetBorder(hwnd, colorref) {
    global S
    if !S.c.border
        return
    c := colorref
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 34, "UInt*", c, "UInt", 4)
}

; ---------------------------------------------------------------------
; monitors
; ---------------------------------------------------------------------
EnumMonProc(hMon, hdc, lprc, lParam) {
    global S
    VarSetCapacity(mi, 104, 0)
    NumPut(104, mi, 0, "UInt")
    DllCall("GetMonitorInfoW", "Ptr", hMon, "Ptr", &mi)
    info := {}
    info.hmon := hMon
    info.x := NumGet(mi, 4, "Int")
    info.y := NumGet(mi, 8, "Int")
    info.w := NumGet(mi, 12, "Int") - info.x
    info.h := NumGet(mi, 16, "Int") - info.y
    info.wx := NumGet(mi, 20, "Int")
    info.wy := NumGet(mi, 24, "Int")
    info.ww := NumGet(mi, 28, "Int") - info.wx
    info.wh := NumGet(mi, 32, "Int") - info.wy
    info.primary := NumGet(mi, 36, "UInt") & 1
    info.dev := StrGet(&mi + 40, 32, "UTF-16")
    dx := 96
    dy := 96
    if (DllCall("shcore\GetDpiForMonitor", "Ptr", hMon, "Int", 0, "UInt*", dx, "UInt*", dy) != 0)
        dx := 96
    info.scale := dx / 96
    S.enumList.Push(info)
    return 1
}

EnumMonitors() {
    global S
    static cb := 0
    S.enumList := []
    if !cb
        cb := RegisterCallback("EnumMonProc", "Fast", 4)
    DllCall("EnumDisplayMonitors", "Ptr", 0, "Ptr", 0, "Ptr", cb, "Ptr", 0)
    list := S.enumList
    ; insertion sort by x then y so indexes are stable left-to-right
    Loop % list.Length() - 1
    {
        i := A_Index + 1
        cur := list[i]
        j := i - 1
        while (j >= 1 && (list[j].x > cur.x || (list[j].x = cur.x && list[j].y > cur.y)))
        {
            list[j + 1] := list[j]
            j--
        }
        list[j + 1] := cur
    }
    ; debug: pretend a monitor is unplugged (fakeunplug / fakereplug commands)
    if (S.fakeHide != "") {
        kept := []
        for i, info in list {
            if (info.dev != S.fakeHide)
                kept.Push(info)
        }
        list := kept
    }
    return list
}

NewWs(id, idx) {
    return {id: id, idx: idx, wins: [], floats: {}, ratio: {}, layout: "bsp", monocle: 0, flip: "", focus: 0, sig: "", nodes: []}
}

NewMon(info) {
    global S
    m := {dev: info.dev, active: 1, last: 1, ws: [], bar: ""}
    Loop % S.c.wsCount
        m.ws.Push(NewWs(info.dev ":" A_Index, A_Index))
    return m
}

CopyGeom(m, info) {
    m.hmon := info.hmon
    m.x := info.x
    m.y := info.y
    m.w := info.w
    m.h := info.h
    m.wx := info.wx
    m.wy := info.wy
    m.ww := info.ww
    m.wh := info.wh
    m.scale := info.scale
    m.primary := info.primary
}

RebuildMonitors() {
    global S
    BarsDestroy()
    infos := EnumMonitors()
    newMons := []
    newByDev := {}
    newByHmon := {}
    for i, info in infos {
        if S.monByDev.HasKey(info.dev)
            m := S.monByDev[info.dev]
        else
            m := NewMon(info)
        CopyGeom(m, info)
        m.idx := i
        newMons.Push(m)
        newByDev[info.dev] := m
        newByHmon[info.hmon] := m
    }
    ; monitors that went away: fold their windows into the first remaining one
    for dev, old in S.monByDev {
        if newByDev.HasKey(dev)
            continue
        target := newMons[1]
        Loop % old.ws.Length()
        {
            k := A_Index
            for j, hw in old.ws[k].wins.Clone()
                MoveWinTo(hw, target, k, 0, true)
        }
        LogMsg("monitor removed: " dev)
    }
    S.mons := newMons
    S.monByDev := newByDev
    S.monByHmon := newByHmon
    if (!S.activeMon || !newByDev.HasKey(S.activeMon.dev))
        S.activeMon := newMons[1]
    for i, m in S.mons {
        SyncVisibility(m)
        Dirty(m)
    }
    BarsCreate()
}

MonitorOfWindow(hwnd) {
    global S
    hm := DllCall("MonitorFromWindow", "Ptr", hwnd, "UInt", 2, "Ptr")
    if S.monByHmon.HasKey(hm)
        return S.monByHmon[hm]
    return S.mons[1]
}

MonitorAtPoint(x, y) {
    global S
    pt := (x & 0xFFFFFFFF) | (y << 32)
    hm := DllCall("MonitorFromPoint", "Int64", pt, "UInt", 2, "Ptr")
    if S.monByHmon.HasKey(hm)
        return S.monByHmon[hm]
    return S.mons[1]
}

OnDisplayChange(wParam, lParam, msg, hwnd) {
    global S
    Arm(S.fnDisplay, -600)
}

OnSettingChange(wParam, lParam, msg, hwnd) {
    global S
    if (wParam = 0x2F)                 ; SPI_SETWORKAREA
        Arm(S.fnWork, -250)
}

HandleDisplayChange() {
    global S
    Critical
    LogMsg("display change")
    RebuildMonitors()
    Flush()
}

RefreshWork() {
    global S
    Critical
    infos := EnumMonitors()
    for i, info in infos {
        if !S.monByDev.HasKey(info.dev)
            continue
        m := S.monByDev[info.dev]
        if (m.wx != info.wx || m.wy != info.wy || m.ww != info.ww || m.wh != info.wh) {
            CopyGeom(m, info)
            Dirty(m)
        }
    }
    Flush()
}

; ---------------------------------------------------------------------
; window tracking
; ---------------------------------------------------------------------
Dirty(m) {
    global S
    S.dirty[m.dev] := m
}

Flush() {
    global S
    d := S.dirty
    S.dirty := {}
    for dev, m in d {
        if S.paused
            continue
        Retile(m)
    }
    BarsRefresh()
}

IndexOf(arr, val) {
    for i, v in arr {
        if (v = val)
            return i
    }
    return 0
}

TryAdd(hwnd, startup := false) {
    global S
    if S.loc.HasKey(hwnd)
        return false
    if (S.reject.HasKey(hwnd) && A_TickCount < S.reject[hwnd])
        return false
    if !IsManageable(hwnd) {
        S.reject[hwnd] := A_TickCount + 1500
        return false
    }
    S.reject.Delete(hwnd)
    m := MonitorOfWindow(hwnd)
    wsIdx := m.active
    if (!startup || S.c.adoptRules) {
        r := RuleWorkspace(hwnd)
        if (r >= 1 && r <= S.c.wsCount)
            wsIdx := r
    }
    ws := m.ws[wsIdx]
    pos := 0
    if (S.focus && S.loc.HasKey(S.focus) && S.loc[S.focus].ws.id = ws.id)
        pos := IndexOf(ws.wins, S.focus)
    if pos
        ws.wins.InsertAt(pos + 1, hwnd)
    else
        ws.wins.Push(hwnd)
    S.loc[hwnd] := {mon: m, ws: ws}
    if IsFloatRule(hwnd)
        ws.floats[hwnd] := 1
    SetBorder(hwnd, S.c.borderUnfocus)
    if (wsIdx != m.active)
        HideWin(hwnd)
    Dirty(m)
    LogMsg("add " hwnd " ws=" wsIdx " [" GetExe(hwnd) "] " GetTitle(hwnd))
    return true
}

; detach from its workspace lists without forgetting the window
Detach(hwnd) {
    global S
    if !S.loc.HasKey(hwnd)
        return
    loc := S.loc[hwnd]
    ws := loc.ws
    i := IndexOf(ws.wins, hwnd)
    if i
        ws.wins.RemoveAt(i)
    ws.floats.Delete(hwnd)
    ws.ratio.Delete(hwnd)
    if (ws.focus = hwnd)
        ws.focus := 0
    Dirty(loc.mon)
}

RemoveWin(hwnd) {
    global S
    if !S.loc.HasKey(hwnd)
        return
    Detach(hwnd)
    S.loc.Delete(hwnd)
    S.hid.Delete(hwnd)
    S.noMove.Delete(hwnd)
    S.borderCache.Delete(hwnd)
    if (S.focus = hwnd)
        S.focus := 0
    Arm(S.fnSave, -300)
}

; move window to monitor mon, workspace wsIdx, at position pos (0 = end)
MoveWinTo(hwnd, mon, wsIdx, pos := 0, silent := false) {
    global S
    isFloat := false
    if S.loc.HasKey(hwnd) {
        isFloat := S.loc[hwnd].ws.floats.HasKey(hwnd)
        Detach(hwnd)
    }
    ws := mon.ws[wsIdx]
    if (pos >= 1 && pos <= ws.wins.Length())
        ws.wins.InsertAt(pos, hwnd)
    else
        ws.wins.Push(hwnd)
    if isFloat
        ws.floats[hwnd] := 1
    S.loc[hwnd] := {mon: mon, ws: ws}
    if (wsIdx = mon.active)
        ShowWin(hwnd)
    else
        HideWin(hwnd)
    Dirty(mon)
}

HideWin(hwnd) {
    global S
    S.hid[hwnd] := 1
    DllCall("ShowWindow", "Ptr", hwnd, "Int", 0)
    Arm(S.fnSave, -300)
}

ShowWin(hwnd) {
    global S
    if S.hid.HasKey(hwnd) {
        S.hid.Delete(hwnd)
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 8)
        Arm(S.fnSave, -300)
    }
}

; show the active workspace's windows, hide every other workspace's
SyncVisibility(m) {
    Loop % m.ws.Length()
    {
        k := A_Index
        for i, hw in m.ws[k].wins {
            if (k = m.active)
                ShowWin(hw)
            else
                HideWin(hw)
        }
    }
}

; periodic safety net: catches windows whose events we missed
Reconcile(startup := false) {
    global S
    Critical
    if S.exiting
        return
    for hwnd, loc in S.loc.Clone() {
        if !DllCall("IsWindow", "Ptr", hwnd)
            RemoveWin(hwnd)
    }
    if (!S.paused) {
        WinGet, ids, List
        Loop, %ids%
        {
            hw := ids%A_Index%
            TryAdd(hw, startup)
        }
    }
    ; layout changes that need no event (minimize, cloak, uncloak)
    for i, m in S.mons {
        ws := m.ws[m.active]
        sig := ListSig(TiledList(ws))
        if (sig != ws.sig)
            Dirty(m)
    }
    Flush()
}

ListSig(list) {
    out := ""
    for i, hw in list
        out .= hw ","
    return out
}

; windows of a workspace that occupy a tile right now
TiledList(ws) {
    global S
    list := []
    for i, hw in ws.wins {
        if ws.floats.HasKey(hw)
            continue
        if S.noMove.HasKey(hw)
            continue
        if !DllCall("IsWindow", "Ptr", hw)
            continue
        if DllCall("IsIconic", "Ptr", hw)
            continue
        if IsCloaked(hw)
            continue
        list.Push(hw)
    }
    return list
}

; ---------------------------------------------------------------------
; layout
; ---------------------------------------------------------------------
ComputeLayout(ws, list, area) {
    n := list.Length()
    rects := []
    ws.nodes := []
    if (ws.monocle) {
        Loop % n
            rects.Push({x: area.x, y: area.y, w: area.w, h: area.h})
        return rects
    }
    lay := ws.layout
    if (lay = "columns") {
        x := area.x
        Loop % n
        {
            w := (A_Index = n) ? (area.x + area.w - x) : Round(area.w / n)
            rects.Push({x: x, y: area.y, w: w, h: area.h})
            x += w
        }
    } else if (lay = "rows") {
        y := area.y
        Loop % n
        {
            h := (A_Index = n) ? (area.y + area.h - y) : Round(area.h / n)
            rects.Push({x: area.x, y: y, w: area.w, h: h})
            y += h
        }
    } else {
        ax := area.x
        ay := area.y
        aw := area.w
        ah := area.h
        ; split direction alternates with depth, starting from the shape of
        ; the whole area. (Choosing by the shape of the REMAINING area made
        ; the layout flip orientation while resizing.)
        firstH := (area.w >= area.h)
        Loop % n
        {
            i := A_Index
            hw := list[i]
            if (i = n) {
                rects.Push({x: ax, y: ay, w: aw, h: ah})
                break
            }
            r := ws.ratio.HasKey(hw) ? ws.ratio[hw] : 0.5
            splitH := (Mod(i, 2) = 1) ? firstH : !firstH
            if (splitH) {
                w1 := Round(aw * r)
                rects.Push({x: ax, y: ay, w: w1, h: ah})
                ax += w1
                aw -= w1
                ws.nodes.Push({axis: "h", key: hw})
            } else {
                h1 := Round(ah * r)
                rects.Push({x: ax, y: ay, w: aw, h: h1})
                ay += h1
                ah -= h1
                ws.nodes.Push({axis: "v", key: hw})
            }
        }
    }
    if InStr(ws.flip, "h") {
        for i, rc in rects
            rc.x := area.x + area.w - (rc.x - area.x) - rc.w
    }
    if InStr(ws.flip, "v") {
        for i, rc in rects
            rc.y := area.y + area.h - (rc.y - area.y) - rc.h
    }
    return rects
}

Retile(m, wsIdx := 0) {
    global S
    if !wsIdx
        wsIdx := m.active
    ws := m.ws[wsIdx]
    list := TiledList(ws)
    ws.sig := ListSig(list)
    if !list.Length()
        return
    po := Round(S.c.padO * m.scale)
    pi := Round(S.c.padI * m.scale)
    area := {x: m.wx + po, y: m.wy + po, w: m.ww - 2 * po, h: m.wh - 2 * po}
    rects := ComputeLayout(ws, list, area)
    for i, hw in list {
        rc := rects[i]
        if !ApplyRect(hw, rc.x + pi, rc.y + pi, rc.w - 2 * pi, rc.h - 2 * pi) {
            S.noMove[hw] := 1
            LogMsg("cannot move " hw " (elevated?) [" GetExe(hw) "]")
        }
    }
    if (ws.monocle && ws.focus && S.loc.HasKey(ws.focus))
        DllCall("SetWindowPos", "Ptr", ws.focus, "Ptr", 0, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x4000 | 0x13)
}

RetileAll() {
    global S
    for i, m in S.mons
        Retile(m)
}

; place a window so that its VISIBLE frame is exactly x,y,w,h
ApplyRect(hwnd, x, y, w, h) {
    global S
    if DllCall("IsZoomed", "Ptr", hwnd)
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)
    VarSetCapacity(wr, 16, 0)
    VarSetCapacity(fr, 16, 0)
    DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", &wr)
    if (DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 9, "Ptr", &fr, "UInt", 16) != 0)
        DllCall("RtlMoveMemory", "Ptr", &fr, "Ptr", &wr, "UPtr", 16)
    dl := NumGet(fr, 0, "Int") - NumGet(wr, 0, "Int")
    dt := NumGet(fr, 4, "Int") - NumGet(wr, 4, "Int")
    dr := NumGet(wr, 8, "Int") - NumGet(fr, 8, "Int")
    db := NumGet(wr, 12, "Int") - NumGet(fr, 12, "Int")
    S.borderCache[hwnd] := [dl, dt, dr, db]
    X := x - dl
    Y := y - dt
    W := w + dl + dr
    H := h + dt + db
    if (X = NumGet(wr, 0, "Int") && Y = NumGet(wr, 4, "Int") && W = NumGet(wr, 8, "Int") - NumGet(wr, 0, "Int") && H = NumGet(wr, 12, "Int") - NumGet(wr, 4, "Int"))
        return true
    ; NOZORDER | NOACTIVATE | NOOWNERZORDER | ASYNCWINDOWPOS
    return DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", 0, "Int", X, "Int", Y, "Int", W, "Int", H, "UInt", 0x4000 | 0x4 | 0x10 | 0x200) ? true : false
}

; ---------------------------------------------------------------------
; win events
; ---------------------------------------------------------------------
RegisterHooks() {
    global S
    S.hooks := []
    S.cb := RegisterCallback("WinEventProc", "", 7)
    ranges := [[0x0003, 0x0003], [0x000B, 0x000B], [0x0016, 0x0017], [0x8001, 0x8003]]
    for i, rg in ranges {
        h := DllCall("SetWinEventHook", "UInt", rg[1], "UInt", rg[2], "Ptr", 0, "Ptr", S.cb, "UInt", 0, "UInt", 0, "UInt", 2, "Ptr")
        S.hooks.Push(h)
        if !h
            LogMsg("SetWinEventHook failed for " rg[1])
    }
}

WinEventProc(hHook, event, hwnd, idObject, idChild, thread, time) {
    Critical
    global S
    idObject &= 0xFFFFFFFF
    idChild &= 0xFFFFFFFF
    if (idObject != 0 || idChild != 0 || !hwnd)
        return
    S.queue.Push([event & 0xFFFFFFFF, hwnd])
    Arm(S.fnQueue, -20)
}

ProcessQueue() {
    Critical
    global S
    q := S.queue
    S.queue := []
    if S.paused
        return
    seen := {}
    for i, e in q {
        key := e[1] ":" e[2]
        if seen.HasKey(key)
            continue
        seen[key] := 1
        HandleEvent(e[1], e[2])
    }
    Flush()
}

HandleEvent(ev, hwnd) {
    global S
    if (ev = 0x0003) {
        OnForeground(hwnd)
        return
    }
    if (ev = 0x8001) {
        if S.loc.HasKey(hwnd)
            RemoveWin(hwnd)
        return
    }
    if (ev = 0x8002) {
        if S.loc.HasKey(hwnd) {
            ; an app re-showed a window we hid: follow it to its workspace
            if S.hid.HasKey(hwnd) {
                loc := S.loc[hwnd]
                if (loc.ws.idx != loc.mon.active)
                    GotoWs(loc.mon, loc.ws.idx, false)
                else
                    ShowWin(hwnd)
            }
            return
        }
        if (GetRoot(hwnd) = hwnd)
            TryAdd(hwnd)
        return
    }
    if (ev = 0x8003) {
        if (S.loc.HasKey(hwnd) && !S.hid.HasKey(hwnd) && !DllCall("IsWindowVisible", "Ptr", hwnd))
            RemoveWin(hwnd)
        return
    }
    if (ev = 0x16 || ev = 0x17) {
        if S.loc.HasKey(hwnd)
            Dirty(S.loc[hwnd].mon)
        return
    }
    if (ev = 0x000B) {
        if S.loc.HasKey(hwnd)
            OnMoveSizeEnd(hwnd)
        return
    }
}

OnForeground(hwnd) {
    global S
    if !S.loc.HasKey(hwnd) {
        if (GetRoot(hwnd) = hwnd)
            TryAdd(hwnd)
    }
    if !S.loc.HasKey(hwnd)
        return
    loc := S.loc[hwnd]
    m := loc.mon
    if (loc.ws.idx != m.active)
        GotoWs(m, loc.ws.idx, false)
    loc.ws.focus := hwnd
    S.activeMon := m
    SetFocusBorder(hwnd)
    S.focus := hwnd
}

SetFocusBorder(hwnd) {
    global S
    if (S.focus && S.focus != hwnd && S.loc.HasKey(S.focus))
        SetBorder(S.focus, S.c.borderUnfocus)
    SetBorder(hwnd, S.c.borderFocus)
}

; user dropped a window after dragging it: swap with the tile under the
; drop point, or send it to another monitor
OnMoveSizeEnd(hwnd) {
    global S
    loc := S.loc[hwnd]
    r := VisRect(hwnd)
    cx := (r.l + r.r) // 2
    cy := (r.t + r.b) // 2
    dest := MonitorAtPoint(cx, cy)
    srcMon := loc.mon
    floating := loc.ws.floats.HasKey(hwnd)
    if (dest.dev != srcMon.dev) {
        MoveWinTo(hwnd, dest, dest.active, 0)
        Dirty(srcMon)
        return
    }
    if floating
        return
    ws := loc.ws
    for i, hw in TiledList(ws) {
        if (hw = hwnd)
            continue
        o := VisRect(hw)
        if (cx >= o.l && cx <= o.r && cy >= o.t && cy <= o.b) {
            a := IndexOf(ws.wins, hwnd)
            b := IndexOf(ws.wins, hw)
            ws.wins[a] := hw
            ws.wins[b] := hwnd
            break
        }
    }
    Dirty(srcMon)
}

; ---------------------------------------------------------------------
; focus / navigation
; ---------------------------------------------------------------------
Focus(hwnd) {
    global S
    if !DllCall("IsWindow", "Ptr", hwnd)
        return
    if DllCall("IsIconic", "Ptr", hwnd)
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 9)
    if (DllCall("GetForegroundWindow", "Ptr") = hwnd)
        return
    if DllCall("SetForegroundWindow", "Ptr", hwnd)
        return
    ; foreground lock: tap Alt (counts as input), then try again
    DllCall("keybd_event", "UChar", 0x12, "UChar", 0, "UInt", 0, "UPtr", 0)
    DllCall("keybd_event", "UChar", 0x12, "UChar", 0, "UInt", 2, "UPtr", 0)
    if DllCall("SetForegroundWindow", "Ptr", hwnd)
        return
    ; last resort: share the input queue of the current foreground window
    fg := DllCall("GetForegroundWindow", "Ptr")
    fgThread := fg ? DllCall("GetWindowThreadProcessId", "Ptr", fg, "UInt*", 0, "UInt") : 0
    me := DllCall("GetCurrentThreadId", "UInt")
    if (fgThread && fgThread != me)
        DllCall("AttachThreadInput", "UInt", me, "UInt", fgThread, "Int", 1)
    DllCall("BringWindowToTop", "Ptr", hwnd)
    DllCall("SetForegroundWindow", "Ptr", hwnd)
    if (fgThread && fgThread != me)
        DllCall("AttachThreadInput", "UInt", me, "UInt", fgThread, "Int", 0)
}

CurrentWin() {
    global S
    hw := DllCall("GetForegroundWindow", "Ptr")
    if (hw && S.loc.HasKey(hw))
        return hw
    if (S.focus && S.loc.HasKey(S.focus) && DllCall("IsWindow", "Ptr", S.focus))
        return S.focus
    return 0
}

CurrentMon() {
    global S
    hw := CurrentWin()
    if hw
        return S.loc[hw].mon
    if S.activeMon
        return S.activeMon
    return S.mons[1]
}

IsTileVisible(hw) {
    if !DllCall("IsWindow", "Ptr", hw)
        return false
    if DllCall("IsIconic", "Ptr", hw)
        return false
    if IsCloaked(hw)
        return false
    return true
}

; nearest window in a direction, scored by distance along the axis plus
; twice the offset across it. sameWs=true restricts to the same workspace.
FindNeighbor(cur, dir, sameWs := false) {
    global S
    cr := VisRect(cur)
    cx := (cr.l + cr.r) / 2
    cy := (cr.t + cr.b) / 2
    curWs := S.loc[cur].ws
    best := 0
    bestScore := 1.0e18
    for i, m in S.mons {
        ws := m.ws[m.active]
        if (sameWs && ws.id != curWs.id)
            continue
        for j, hw in ws.wins {
            if (hw = cur || S.hid.HasKey(hw))
                continue
            if (sameWs && ws.floats.HasKey(hw))
                continue
            if !IsTileVisible(hw)
                continue
            r := VisRect(hw)
            dx := (r.l + r.r) / 2 - cx
            dy := (r.t + r.b) / 2 - cy
            if (dir = "left") {
                if (dx >= -1)
                    continue
                along := -dx
                across := Abs(dy)
            } else if (dir = "right") {
                if (dx <= 1)
                    continue
                along := dx
                across := Abs(dy)
            } else if (dir = "up") {
                if (dy >= -1)
                    continue
                along := -dy
                across := Abs(dx)
            } else {
                if (dy <= 1)
                    continue
                along := dy
                across := Abs(dx)
            }
            score := along + 2 * across
            if (score < bestScore) {
                bestScore := score
                best := hw
            }
        }
    }
    return best
}

FocusDir(dir) {
    global S
    cur := CurrentWin()
    if !cur
        return
    nb := FindNeighbor(cur, dir, false)
    if nb
        Focus(nb)
}

MoveDir(dir) {
    global S
    cur := CurrentWin()
    if !cur
        return
    loc := S.loc[cur]
    if loc.ws.floats.HasKey(cur)
        return
    nb := FindNeighbor(cur, dir, true)
    if nb {
        ws := loc.ws
        a := IndexOf(ws.wins, cur)
        b := IndexOf(ws.wins, nb)
        ws.wins[a] := nb
        ws.wins[b] := cur
        Dirty(loc.mon)
        return
    }
    ; nothing left in this workspace: hop to the monitor in that direction
    nb := FindNeighbor(cur, dir, false)
    if (nb && S.loc.HasKey(nb) && S.loc[nb].mon.dev != loc.mon.dev) {
        dest := S.loc[nb].mon
        at := IndexOf(dest.ws[dest.active].wins, nb)
        MoveWinTo(cur, dest, dest.active, at)
        Dirty(loc.mon)
        Focus(cur)
    }
}

CycleFocus() {
    global S
    cur := CurrentWin()
    if !cur
        return
    list := TiledList(S.loc[cur].ws)
    if (list.Length() < 2)
        return
    i := IndexOf(list, cur)
    Focus(list[Mod(i, list.Length()) + 1])
}

Promote() {
    global S
    cur := CurrentWin()
    if !cur
        return
    loc := S.loc[cur]
    ws := loc.ws
    i := IndexOf(ws.wins, cur)
    if (i > 1) {
        ws.wins.RemoveAt(i)
        ws.wins.InsertAt(1, cur)
        Dirty(loc.mon)
    }
}

ResizeAxis(axis, delta) {
    global S
    cur := CurrentWin()
    if !cur
        return
    loc := S.loc[cur]
    ws := loc.ws
    if (ws.layout != "bsp" || ws.monocle || ws.floats.HasKey(cur))
        return
    list := TiledList(ws)
    k := IndexOf(list, cur)
    if !k
        return
    nodes := ws.nodes
    i := (k <= nodes.Length()) ? k : nodes.Length()
    while (i >= 1)
    {
        nd := nodes[i]
        if (nd.axis = axis) {
            r := ws.ratio.HasKey(nd.key) ? ws.ratio[nd.key] : 0.5
            r := (i = k) ? r + delta : r - delta
            if (r < 0.1)
                r := 0.1
            if (r > 0.9)
                r := 0.9
            ws.ratio[nd.key] := r
            Dirty(loc.mon)
            return
        }
        i--
    }
}

ToggleFloat() {
    global S
    cur := CurrentWin()
    if !cur
        return
    loc := S.loc[cur]
    if loc.ws.floats.HasKey(cur)
        loc.ws.floats.Delete(cur)
    else
        loc.ws.floats[cur] := 1
    S.noMove.Delete(cur)
    Dirty(loc.mon)
}

; ---------------------------------------------------------------------
; workspaces
; ---------------------------------------------------------------------
GotoWs(m, n, focus := true) {
    global S
    if (n < 1 || n > S.c.wsCount || n = m.active)
        return
    newWs := m.ws[n]
    ; lay out the target workspace while its windows are still hidden
    Retile(m, n)
    m.last := m.active
    m.active := n
    SyncVisibility(m)
    S.activeMon := m
    Dirty(m)
    if focus {
        hw := newWs.focus
        if !(hw && S.loc.HasKey(hw) && IsTileVisible(hw)) {
            hw := 0
            for i, w in newWs.wins {
                if IsTileVisible(w) {
                    hw := w
                    break
                }
            }
        }
        if hw
            Focus(hw)
    }
}

MoveToWs(n) {
    global S
    cur := CurrentWin()
    if !cur
        return
    loc := S.loc[cur]
    m := loc.mon
    if (n < 1 || n > S.c.wsCount || n = loc.ws.idx)
        return
    MoveWinTo(cur, m, n, 0)
    GotoWs(m, n, false)
    Focus(cur)
}

MoveToMonitor(step) {
    global S
    cur := CurrentWin()
    if !cur
        return
    if (S.mons.Length() < 2)
        return
    loc := S.loc[cur]
    i := loc.mon.idx + step
    if (i < 1)
        i := S.mons.Length()
    if (i > S.mons.Length())
        i := 1
    dest := S.mons[i]
    src := loc.mon
    MoveWinTo(cur, dest, dest.active, 0)
    Dirty(src)
    Focus(cur)
}

; ---------------------------------------------------------------------
; hotkeys and actions
; ---------------------------------------------------------------------
RegisterHotkeys() {
    global S
    S.hk := {}
    okCount := 0
    failed := 0
    for i, sec in ["hotkeys", "launch"] {
        IniRead, txt, % S.ini, % sec
        if (txt = "ERROR")
            continue
        Loop, Parse, txt, `n, `r
        {
            line := A_LoopField
            if (line = "" || SubStr(line, 1, 1) = ";")
                continue
            p := InStr(line, "=")
            if (p < 2)
                continue
            hk := Trim(SubStr(line, 1, p - 1))
            act := Trim(SubStr(line, p + 1))
            if (sec = "launch")
                act := "run:" act
            S.hk[hk] := act
            Hotkey, %hk%, HotkeyHandler, UseErrorLevel
            if ErrorLevel {
                failed++
                LogMsg("hotkey failed: " hk " (" ErrorLevel ")")
            } else
                okCount++
        }
    }
    LogMsg("hotkeys registered=" okCount " failed=" failed)
}

DoAction(name) {
    global S
    Critical
    if (name = "")
        return
    if (S.paused && name != "pause" && name != "quit" && name != "reload")
        return
    if (SubStr(name, 1, 4) = "run:") {
        Run, % SubStr(name, 5),, UseErrorLevel
        return
    }
    if RegExMatch(name, "^goto_(\d+)$", g) {
        GotoWs(CurrentMon(), g1 + 0)
    } else if RegExMatch(name, "^movews_(\d+)$", g) {
        MoveToWs(g1 + 0)
    } else if RegExMatch(name, "^focus_(left|right|up|down)$", g) {
        FocusDir(g1)
    } else if RegExMatch(name, "^move_(left|right|up|down)$", g) {
        MoveDir(g1)
    } else if (name = "resize_h_inc") {
        ResizeAxis("h", 0.05)
    } else if (name = "resize_h_dec") {
        ResizeAxis("h", -0.05)
    } else if (name = "resize_v_inc") {
        ResizeAxis("v", 0.05)
    } else if (name = "resize_v_dec") {
        ResizeAxis("v", -0.05)
    } else if (name = "promote") {
        Promote()
    } else if (name = "toggle_float") {
        ToggleFloat()
    } else if (name = "toggle_monocle") {
        m := CurrentMon()
        ws := m.ws[m.active]
        ws.monocle := !ws.monocle
        Dirty(m)
    } else if (name = "cycle_layout") {
        m := CurrentMon()
        ws := m.ws[m.active]
        ws.layout := (ws.layout = "bsp") ? "columns" : (ws.layout = "columns" ? "rows" : "bsp")
        Dirty(m)
    } else if (name = "flip_h") {
        m := CurrentMon()
        ws := m.ws[m.active]
        ws.flip := InStr(ws.flip, "h") ? StrReplace(ws.flip, "h") : ws.flip "h"
        Dirty(m)
    } else if (name = "flip_v") {
        m := CurrentMon()
        ws := m.ws[m.active]
        ws.flip := InStr(ws.flip, "v") ? StrReplace(ws.flip, "v") : ws.flip "v"
        Dirty(m)
    } else if (name = "cycle_focus") {
        CycleFocus()
    } else if (name = "minimize") {
        hw := CurrentWin()
        if hw
            DllCall("ShowWindow", "Ptr", hw, "Int", 6)
    } else if (name = "close") {
        hw := DllCall("GetForegroundWindow", "Ptr")
        if (!hw || GetRoot(hw) != hw)
            hw := CurrentWin()
        if hw
            PostMessage, 0x10, 0, 0,, ahk_id %hw%
    } else if (name = "ws_next") {
        m := CurrentMon()
        GotoWs(m, m.active >= S.c.wsCount ? 1 : m.active + 1)
    } else if (name = "ws_prev") {
        m := CurrentMon()
        GotoWs(m, m.active <= 1 ? S.c.wsCount : m.active - 1)
    } else if (name = "ws_last") {
        m := CurrentMon()
        GotoWs(m, m.last)
    } else if (name = "monitor_next") {
        MoveToMonitor(1)
    } else if (name = "monitor_prev") {
        MoveToMonitor(-1)
    } else if (name = "retile") {
        for i, m in S.mons
            Dirty(m)
    } else if (name = "pause") {
        S.paused := !S.paused
        if !S.paused {
            for i, m in S.mons
                Dirty(m)
        }
    } else if (name = "reload") {
        ; AHK v1's Reload drops command-line arguments, so restart by hand
        ; clean up first (bars, hidden windows) so the new instance never has to
        ; wait for this one to shut down
        q := Chr(34)
        Cleanup("reload", 0)
        Run, % q A_AhkPath q " " q A_ScriptFullPath q " --ini=" q S.ini q
        ExitApp
    } else if (name = "quit") {
        ExitApp
    } else if (name = "dump") {
        Dump()
    } else {
        LogMsg("unknown action: " name)
    }
    Flush()
}

; ---------------------------------------------------------------------
; debug command channel (only with debug=1): lines in tiler.cmd
; ---------------------------------------------------------------------
PollCmd() {
    global S
    f := S.dir "\tiler.cmd"
    if !FileExist(f)
        return
    FileRead, txt, %f%
    FileDelete, %f%
    Loop, Parse, txt, `n, `r
    {
        line := Trim(A_LoopField)
        if (line = "")
            continue
        LogMsg("cmd: " line)
        if (line = "dump")
            Dump()
        else if (SubStr(line, 1, 5) = "shot ")
            ShotRun(SubStr(line, 6))
        else if (SubStr(line, 1, 11) = "fakeunplug ") {
            S.fakeHide := SubStr(line, 12)
            HandleDisplayChange()
        } else if (line = "fakereplug") {
            S.fakeHide := ""
            HandleDisplayChange()
        } else if (SubStr(line, 1, 5) = "send ")
            SendInput, % SubStr(line, 6)
        else if (SubStr(line, 1, 6) = "chord ")
            KeyChord(SubStr(line, 7))
        else if (line = "classify")
            Classify()
        else if (SubStr(line, 1, 11) = "focustitle ")
            FocusTitle(SubStr(line, 12))
        else if (SubStr(line, 1, 8) = "bardump ")
            BarDump(SubStr(line, 9))
        else if (SubStr(line, 1, 7) = "reject ")
            S.reject.Delete(SubStr(line, 8) + 0)
        else
            DoAction(line)
    }
}

; debug: press a chord of virtual-key codes (comma separated, hex) with plain
; keybd_event, e.g. "0x11,0x12,0x27" = Ctrl+Alt+Right
KeyChord(list) {
    vks := StrSplit(list, ",")
    for i, vk in vks {
        DllCall("keybd_event", "UChar", vk + 0, "UChar", 0, "UInt", 0, "UPtr", 0)
        Sleep, 40
    }
    Loop % vks.Length()
    {
        vk := vks[vks.Length() - A_Index + 1]
        DllCall("keybd_event", "UChar", vk + 0, "UChar", 0, "UInt", 2, "UPtr", 0)
        Sleep, 40
    }
}

FocusTitle(t) {
    global S
    for hw in S.loc {
        if (GetTitle(hw) = t) {
            Focus(hw)
            return
        }
    }
}

ShotRun(path) {
    global S
    q := Chr(34)
    cmd := "powershell -NoProfile -ExecutionPolicy Bypass -File " q S.dir "\tools\shot.ps1" q " " q path q
    Run, %cmd%,, Hide
}

Dump() {
    global S
    out := "time " A_Now "`n"
    out .= "paused " S.paused "`n"
    out .= "focus " S.focus "`n"
    for i, m in S.mons {
        out .= "MON " i " dev=" m.dev " rect=" m.x "," m.y "," m.w "," m.h " work=" m.wx "," m.wy "," m.ww "," m.wh " scale=" m.scale " active=" m.active " last=" m.last "`n"
        if (m.bar) {
            WinGetPos, bx, by, bw, bh, % "ahk_id " m.bar.hwnd
            out .= "  BAR hwnd=" m.bar.hwnd " rect=" bx "," by "," bw "," bh "`n"
        }
        Loop % m.ws.Length()
        {
            ws := m.ws[A_Index]
            if !ws.wins.Length()
                continue
            out .= "  WS " ws.idx " layout=" ws.layout " monocle=" ws.monocle " flip=" ws.flip "`n"
            for j, hw in ws.wins {
                r := VisRect(hw)
                t := StrReplace(GetTitle(hw), "`n", " ")
                out .= "    WIN " hw " hidden=" (S.hid.HasKey(hw) ? 1 : 0) " float=" (ws.floats.HasKey(hw) ? 1 : 0) " rect=" r.l "," r.t "," (r.r - r.l) "," (r.b - r.t) " exe=" GetExe(hw) " title=" t "`n"
            }
        }
    }
    f := FileOpen(S.dir "\tiler.state", "w")
    f.Write(out)
    f.Close()
}

; ---------------------------------------------------------------------
; selftest: layout math without touching any window
; ---------------------------------------------------------------------
SelfTest() {
    global S
    out := ""
    for li, lay in ["bsp", "columns", "rows"] {
        Loop 6
        {
            n := A_Index
            ws := NewWs("t", 1)
            ws.layout := lay
            list := []
            Loop % n
                list.Push(1000 + A_Index)
            rects := ComputeLayout(ws, list, {x: 6, y: 40, w: 1354, h: 722})
            for i, rc in rects
                out .= lay " " n " " i " " rc.x " " rc.y " " rc.w " " rc.h "`n"
        }
    }
    FileDelete, % S.dir "\selftest.txt"
    FileAppend, %out%, % S.dir "\selftest.txt"
}

; ---------------------------------------------------------------------
; bar (layered window drawn with GDI+, registered as an AppBar)
; ---------------------------------------------------------------------
GdipStart() {
    VarSetCapacity(si, 8 + 2 * A_PtrSize, 0)
    NumPut(1, si, 0, "UInt")
    tok := 0
    DllCall("gdiplus\GdiplusStartup", "Ptr*", tok, "Ptr", &si, "Ptr", 0)
    return tok
}

AppBarMsg(msg, m, edge, l, t, r, b) {
    sz := 3 * A_PtrSize + 24
    VarSetCapacity(abd, sz, 0)
    NumPut(sz, abd, 0, "UInt")
    NumPut(m.bar.hwnd, abd, A_PtrSize, "Ptr")
    NumPut(0x8100 + m.idx, abd, 2 * A_PtrSize, "UInt")
    NumPut(edge, abd, 2 * A_PtrSize + 4, "UInt")
    NumPut(l, abd, 2 * A_PtrSize + 8, "Int")
    NumPut(t, abd, 2 * A_PtrSize + 12, "Int")
    NumPut(r, abd, 2 * A_PtrSize + 16, "Int")
    NumPut(b, abd, 2 * A_PtrSize + 20, "Int")
    DllCall("shell32\SHAppBarMessage", "UInt", msg, "Ptr", &abd, "UPtr")
    return {l: NumGet(abd, 2 * A_PtrSize + 8, "Int"), t: NumGet(abd, 2 * A_PtrSize + 12, "Int"), r: NumGet(abd, 2 * A_PtrSize + 16, "Int"), b: NumGet(abd, 2 * A_PtrSize + 20, "Int")}
}

BarsCreate() {
    global S
    if !S.c.bar
        return
    for i, m in S.mons
        BarCreate(m)
}

BarCreate(m) {
    global S
    n := m.idx
    H := Round(S.c.barH * m.scale)
    W := m.w
    top := (S.c.barPos != "bottom")
    X := m.x
    Y := top ? m.y : m.y + m.h - H
    Gui, bar%n%:New, -Caption +ToolWindow +AlwaysOnTop +E0x80000 +E0x8000000 +HwndhB
    Gui, bar%n%:Show, NoActivate x%X% y%Y% w%W% h%H%
    m.bar := {hwnd: hB, w: W, h: H, x: X, y: Y, sig: "", pills: [], layoutX: [0, 0]}
    ; reserve the strip so maximized windows and our own layout respect it
    AppBarMsg(0, m, top ? 1 : 3, X, Y, X + W, Y + H)
    rc := AppBarMsg(2, m, top ? 1 : 3, m.x, m.y, m.x + m.w, m.y + m.h)
    if top
        rc.b := rc.t + H
    else
        rc.t := rc.b - H
    AppBarMsg(3, m, top ? 1 : 3, rc.l, rc.t, rc.r, rc.b)
    m.bar.x := rc.l
    m.bar.y := rc.t
    m.bar.w := rc.r - rc.l
    DllCall("SetWindowPos", "Ptr", hB, "Ptr", -1, "Int", rc.l, "Int", rc.t, "Int", rc.r - rc.l, "Int", H, "UInt", 0x10)
    Arm(S.fnWork, -300)
}

BarsDestroy() {
    global S
    for i, m in S.mons {
        if !m.bar
            continue
        AppBarMsg(1, m, 1, 0, 0, 0, 0)
        n := m.idx
        Gui, bar%n%:Destroy
        m.bar := ""
    }
}

BarsRefresh() {
    global S
    for i, m in S.mons
        BarDraw(m)
}

BarModel(m) {
    global S
    c := S.c
    mdl := {}
    pills := []
    Loop % c.wsCount
    {
        i := A_Index
        cnt := m.ws[i].wins.Length()
        if (c.hideEmpty && i != m.active && !cnt)
            continue
        pills.Push({ws: i, active: (i = m.active), empty: (cnt = 0)})
    }
    ws := m.ws[m.active]
    lay := ws.monocle ? "MONO" : (ws.layout = "bsp" ? "BSP" : (ws.layout = "columns" ? "COL" : "ROW"))
    if S.paused
        lay := "PAUSED"
    title := ""
    hw := ws.focus
    if (hw && S.loc.HasKey(hw) && DllCall("IsWindow", "Ptr", hw))
        title := GetTitle(hw)
    if (StrLen(title) > 80)
        title := SubStr(title, 1, 77) "..."
    right := []
    for i, wd in StrSplit(c.right, ",") {
        wd := Trim(wd)
        if (wd = "cpu")
            right.Push("CPU " S.cpu "%")
        else if (wd = "ram")
            right.Push("RAM " S.ram "%")
        else if (wd = "battery") {
            bt := BatteryText()
            if (bt != "")
                right.Push(bt)
        } else if (wd = "date") {
            FormatTime, ds,, ddd dd/MM/yyyy
            right.Push(ds)
        } else if (wd = "time") {
            FormatTime, ts,, HH:mm
            right.Push(ts)
        }
    }
    sig := lay "|" title "|"
    for i, p in pills
        sig .= p.ws (p.active ? "*" : "") (p.empty ? "_" : "") ","
    for i, r in right
        sig .= "|" r
    mdl.pills := pills
    mdl.lay := lay
    mdl.title := title
    mdl.right := right
    mdl.sig := sig
    return mdl
}

BatteryText() {
    VarSetCapacity(sp, 16, 0)
    if !DllCall("GetSystemPowerStatus", "Ptr", &sp)
        return ""
    flag := NumGet(sp, 1, "UChar")
    pct := NumGet(sp, 2, "UChar")
    ac := NumGet(sp, 0, "UChar")
    if (flag = 128 || pct = 255)
        return ""
    return "BAT " pct "%" (ac = 1 ? "+" : "")
}

GBrush(argb) {
    br := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", br)
    return br
}

GFillRound(pG, brush, x, y, w, h, r) {
    path := 0
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", path)
    d := r * 2
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x, "Float", y, "Float", d, "Float", d, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y, "Float", d, "Float", d, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y + h - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x, "Float", y + h - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", path)
    DllCall("gdiplus\GdipFillPath", "Ptr", pG, "Ptr", brush, "Ptr", path)
    DllCall("gdiplus\GdipDeletePath", "Ptr", path)
}

GText(pG, text, font, fmt, brush, x, y, w, h) {
    VarSetCapacity(rc, 16, 0)
    NumPut(x, rc, 0, "Float")
    NumPut(y, rc, 4, "Float")
    NumPut(w, rc, 8, "Float")
    NumPut(h, rc, 12, "Float")
    DllCall("gdiplus\GdipDrawString", "Ptr", pG, "WStr", text, "Int", -1, "Ptr", font, "Ptr", &rc, "Ptr", fmt, "Ptr", brush)
}

GMeasure(pG, text, font, fmt) {
    VarSetCapacity(rc, 16, 0)
    NumPut(2000, rc, 8, "Float")
    NumPut(200, rc, 12, "Float")
    VarSetCapacity(bb, 16, 0)
    DllCall("gdiplus\GdipMeasureString", "Ptr", pG, "WStr", text, "Int", -1, "Ptr", font, "Ptr", &rc, "Ptr", fmt, "Ptr", &bb, "Ptr", 0, "Ptr", 0)
    return NumGet(bb, 8, "Float")
}

BarDraw(m) {
    global S
    b := m.bar
    if !b
        return
    mdl := BarModel(m)
    if (mdl.sig = b.sig)
        return
    b.sig := mdl.sig
    c := S.c
    W := b.w
    H := b.h
    sc := m.scale
    hdcS := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdc := DllCall("CreateCompatibleDC", "Ptr", hdcS, "Ptr")
    VarSetCapacity(bi, 40, 0)
    NumPut(40, bi, 0, "UInt")
    NumPut(W, bi, 4, "Int")
    NumPut(-H, bi, 8, "Int")
    NumPut(1, bi, 12, "UShort")
    NumPut(32, bi, 14, "UShort")
    pBits := 0
    hbm := DllCall("CreateDIBSection", "Ptr", hdc, "Ptr", &bi, "UInt", 0, "Ptr*", pBits, "Ptr", 0, "UInt", 0, "Ptr")
    obm := DllCall("SelectObject", "Ptr", hdc, "Ptr", hbm, "Ptr")
    pG := 0
    DllCall("gdiplus\GdipCreateFromHDC", "Ptr", hdc, "Ptr*", pG)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pG, "Int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", pG, "Int", 4)
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", pG, "UInt", c.cBg)
    fam := 0
    if (DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", c.barFont, "Ptr", 0, "Ptr*", fam) != 0)
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "Segoe UI", "Ptr", 0, "Ptr*", fam)
    font := 0
    DllCall("gdiplus\GdipCreateFont", "Ptr", fam, "Float", c.barFontSize * sc, "Int", 0, "Int", 2, "Ptr*", font)
    fmt := 0
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0x1000, "UShort", 0, "Ptr*", fmt)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", fmt, "Int", 1)
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmt, "Int", 1)
    fmtL := 0
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0x1000, "UShort", 0, "Ptr*", fmtL)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", fmtL, "Int", 0)
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmtL, "Int", 1)
    bChip := GBrush(c.cChip)
    bAcc := GBrush(c.cAccent)
    bFg := GBrush(c.cFg)
    bDim := GBrush(c.cDim)
    bBg := GBrush(c.cBg)
    pad := 4 * sc
    rad := 5 * sc
    ph := H - 2 * pad
    x := 6 * sc
    b.pills := []
    for i, p in mdl.pills {
        if p.active {
            GFillRound(pG, bAcc, x, pad, ph, ph, rad)
            GText(pG, p.ws, font, fmt, bBg, x, pad, ph, ph)
        } else {
            GFillRound(pG, bChip, x, pad, ph, ph, rad)
            GText(pG, p.ws, font, fmt, p.empty ? bDim : bFg, x, pad, ph, ph)
        }
        b.pills.Push({x1: x, x2: x + ph, ws: p.ws})
        x += ph + 4 * sc
    }
    ; layout chip
    lw := GMeasure(pG, mdl.lay, font, fmtL) + 14 * sc
    GFillRound(pG, bChip, x, pad, lw, ph, rad)
    GText(pG, mdl.lay, font, fmt, bFg, x, pad, lw, ph)
    b.layoutX := [x, x + lw]
    x += lw + 10 * sc
    ; right side, laid out from the right edge
    rx := W - 6 * sc
    Loop % mdl.right.Length()
    {
        txt := mdl.right[mdl.right.Length() - A_Index + 1]
        cw := GMeasure(pG, txt, font, fmtL) + 14 * sc
        rx -= cw
        GFillRound(pG, bChip, rx, pad, cw, ph, rad)
        GText(pG, txt, font, fmt, bFg, rx, pad, cw, ph)
        rx -= 4 * sc
    }
    ; focused window title between the two groups
    tw := rx - x - 8 * sc
    if (tw < 10)
        tw := 10
    if (mdl.title != "")
        GText(pG, mdl.title, font, fmtL, bFg, x, 0, tw, H)
    ; push to the layered window
    VarSetCapacity(ptD, 8, 0)
    NumPut(b.x, ptD, 0, "Int")
    NumPut(b.y, ptD, 4, "Int")
    VarSetCapacity(szW, 8, 0)
    NumPut(W, szW, 0, "Int")
    NumPut(H, szW, 4, "Int")
    VarSetCapacity(ptS, 8, 0)
    VarSetCapacity(bf, 4, 0)
    NumPut(255, bf, 2, "UChar")
    NumPut(1, bf, 3, "UChar")
    DllCall("UpdateLayeredWindow", "Ptr", b.hwnd, "Ptr", hdcS, "Ptr", &ptD, "Ptr", &szW, "Ptr", hdc, "Ptr", &ptS, "UInt", 0, "Ptr", &bf, "UInt", 2)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", bChip)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", bAcc)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", bFg)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", bDim)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", bBg)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmt)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmtL)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", font)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", fam)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pG)
    DllCall("SelectObject", "Ptr", hdc, "Ptr", obm)
    if (S.barDump != "")
        SaveBarPng(hbm, S.barDump "_" m.idx ".png")
    DllCall("DeleteObject", "Ptr", hbm)
    DllCall("DeleteDC", "Ptr", hdc)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcS)
}

; debug helper: write the bar bitmap of every monitor to <prefix>_<n>.png
SaveBarPng(hbm, path) {
    pBmp := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", pBmp)
    VarSetCapacity(clsid, 16, 0)
    DllCall("ole32\CLSIDFromString", "WStr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", &clsid)
    DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBmp, "WStr", path, "Ptr", &clsid, "Ptr", 0)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
}

BarDump(prefix) {
    global S
    S.barDump := prefix
    for i, m in S.mons {
        if m.bar
            m.bar.sig := ""
    }
    BarsRefresh()
    S.barDump := ""
}

OnBarClick(wParam, lParam, msg, hwnd) {
    global S
    for i, m in S.mons {
        if (!m.bar || m.bar.hwnd != hwnd)
            continue
        x := lParam & 0xFFFF
        for j, p in m.bar.pills {
            if (x >= p.x1 && x <= p.x2) {
                GotoWs(m, p.ws)
                Flush()
                return 0
            }
        }
        if (x >= m.bar.layoutX[1] && x <= m.bar.layoutX[2]) {
            S.activeMon := m
            DoAction("cycle_layout")
        }
        return 0
    }
}

; ---------------------------------------------------------------------
; 1 Hz tick: cpu / ram / clock
; ---------------------------------------------------------------------
Tick() {
    Critical
    global S
    idle := 0
    kern := 0
    user := 0
    DllCall("GetSystemTimes", "Int64*", idle, "Int64*", kern, "Int64*", user)
    dI := idle - S.lastIdle
    dT := (kern - S.lastKern) + (user - S.lastUser)
    if (S.lastKern && dT > 0)
        S.cpu := Round((1 - dI / dT) * 100)
    S.lastIdle := idle
    S.lastKern := kern
    S.lastUser := user
    VarSetCapacity(ms, 64, 0)
    NumPut(64, ms, 0, "UInt")
    DllCall("GlobalMemoryStatusEx", "Ptr", &ms)
    S.ram := NumGet(ms, 4, "UInt")
    S.exeCache := {}
    BarsRefresh()
}
