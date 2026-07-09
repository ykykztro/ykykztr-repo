; ============================================================
;  WindowQuickJump.ahk — 窗口/标签页编号直达工具
;  AHK v2       Alt+1~9 绑定/切换    Ctrl+Alt+1~9 强制覆盖
; ============================================================

#Requires AutoHotkey v2.0

; === 自动提权 ===
if !A_IsAdmin {
    Run '*RunAs "' A_ScriptFullPath '"'
    ExitApp
}

; === 全局设置 ===
SetTitleMatchMode 2
GroupAdd "QJSelf", "ahk_class AutoHotkey"

; === 数据槽位 ===
Slot := []
Slot.Length := 9
Loop 9
    Slot[A_Index] := 0

; === 浏览器类名 ===
BrowserClasses := ["Chrome_WidgetWin_1", "Chrome_WidgetWin_0"]

; === 辅助函数：屏幕中央提示 ===
ShowTip(msg, ms := 1500) {
    ToolTip msg, A_ScreenWidth // 2, A_ScreenHeight // 2 - 50
    SetTimer () => ToolTip(), -ms
}

; === 判断是否为浏览器 ===
IsBrowser(hwnd) {
    global BrowserClasses

    cls := WinGetClass("ahk_id " hwnd)
    for c in BrowserClasses {
        if cls = c
            return true
    }
    return false
}

; === 绑定当前窗口 ===
BindWindow(n, *) {
    global Slot

    hwnd := WinExist("A")
    if !hwnd || WinActive("ahk_group QJSelf") {
        ShowTip("不能绑定此窗口", 1500)
        return
    }

    title := WinGetTitle("ahk_id " hwnd)
    Slot[n] := { hwnd: hwnd, title: title }
    ShowTip("Slot " n " 已绑定: " title, 2000)
}

; === 跳转到绑定窗口 ===
JumpToWindow(n) {
    global Slot

    s := Slot[n]
    if !s {
        ShowTip("Slot " n " 未绑定", 1500)
        return
    }

    if !WinExist("ahk_id " s.hwnd) {
        ShowTip("Slot " n " 窗口已关闭: " s.title, 3000)
        Slot[n] := 0
        return
    }

    WinActivate("ahk_id " s.hwnd)
    Sleep 100
    if IsBrowser(s.hwnd)
        CycleBrowserTabs(s.hwnd, s.title, n)
    else
        ShowTip("Slot " n ": " s.title, 1200)
}

; === 浏览器标签页轮询 ===
CycleBrowserTabs(hwnd, targetTitle, n) {
    cur := WinGetTitle("ahk_id " hwnd)
    if InStr(cur, targetTitle) {
        ShowTip("Slot " n ": " targetTitle, 1200)
        return
    }

    Loop 30 {
        SendInput "^{Tab}"
        Sleep 55
        cur := WinGetTitle("ahk_id " hwnd)
        if InStr(cur, targetTitle) {
            ShowTip("Slot " n " 已定位: " targetTitle, 1500)
            return
        }
    }

    ShowTip("Slot " n " 未找到: " targetTitle, 3000)
}

; === 注册快捷键 1~9 ===
Loop 9 {
    n := A_Index
    Hotkey "!" n, QuickJump.Bind(n)
    Hotkey "^!" n, BindWindow.Bind(n)
}

QuickJump(n, *) {
    global Slot

    if Slot[n]
        JumpToWindow(n)
    else
        BindWindow(n)
}

; === 退出清理 ===
OnExit(Cleanup)

Cleanup(*) {
    global Slot

    Loop 9
        Slot[A_Index] := 0
    ToolTip "QuickJump 已退出"
    Sleep 500
}

; === 启动提示 ===
ShowTip("WindowQuickJump 已启动`nAlt+1~9 绑定/切换 | Ctrl+Alt+1~9 强制覆盖", 3000)