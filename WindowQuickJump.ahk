; ============================================================
;  WindowQuickJump.ahk — 窗口/标签页编号直达工具
;  AHK v2       Alt+1~9 绑定/切换    Ctrl+Alt+1~9 强制覆盖
;  支持：浏览器标签页 / VS Code 编辑器（按标题定位）
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

; === 判断应用类型 ===
;  注意：VS Code 与 Chrome 同属 Chrome_WidgetWin_1 窗口类，
;  因此必须先按进程名区分 Code.exe，否则会被误判为浏览器而用错按键。
GetApp(hwnd) {
    global BrowserClasses

    try proc := WinGetProcessName("ahk_id " hwnd)
    if (proc = "Code.exe")
        return "VSCode"

    cls := WinGetClass("ahk_id " hwnd)
    for c in BrowserClasses {
        if cls = c
            return "Browser"
    }
    return "Other"
}

; === 从 VS Code 窗口标题中提取当前编辑器文件名 ===
;  标题格式通常为 "文件名.ext - 项目名 - Visual Studio Code"，
;  取第一段并去掉未保存标记 ● / *。
VSCodeFileName(title) {
    t := title
    ; 去掉后缀 " - Visual Studio Code"
    idx := InStr(t, " - Visual Studio Code")
    if idx
        t := SubStr(t, 1, idx - 1)
    ; 第一段（按 " - " 或 " — " 分隔）即为文件名
    if InStr(t, " - ")
        t := SubStr(t, 1, InStr(t, " - ") - 1)
    else if InStr(t, " — ")
        t := SubStr(t, 1, InStr(t, " — ") - 1)
    ; 去掉未保存标记 ● / *
    while (SubStr(t, 1, 1) = "●" || SubStr(t, 1, 1) = "*")
        t := SubStr(t, 2)
    return Trim(t)
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

; === 标签页轮询（浏览器，按完整标题包含匹配）===
;  必须使用 Ctrl+PageDown 按标签"顺序"遍历：Chrome/Edge 的 Ctrl+Tab 默认按
;  "最近使用"顺序切换，只会来回跳转最后两个标签，永远遍历不到其它标签——
;  这正是"多开一个页面就找不到"的根因。Ctrl+PageDown 会左→右依次经过每个
;  标签并在末尾回环到第一个。
CycleBrowserTabs(hwnd, targetTitle, n) {
    cur := WinGetTitle("ahk_id " hwnd)
    if InStr(cur, targetTitle) {
        ShowTip("Slot " n ": " targetTitle, 1200)
        return
    }

    start := cur
    prev := cur
    ; 最多尝试 30 次；转完一圈(回到起点)或按键不再推进即停止
    Loop 30 {
        SendInput "^{PgDn}"
        Sleep 60
        cur := WinGetTitle("ahk_id " hwnd)
        if InStr(cur, targetTitle) {
            ShowTip("Slot " n " 已定位: " targetTitle, 1500)
            return
        }
        ; 已绕回起点 → 全部标签页都不匹配，提前结束
        if (cur = start) {
            ShowTip("Slot " n " 未找到: " targetTitle, 2500)
            return
        }
        ; 按键没有推进（标签未变化，部分浏览器不回环）→ 避免空转到上限
        if (cur = prev) {
            ShowTip("Slot " n " 未找到: " targetTitle, 2500)
            return
        }
        prev := cur
    }

    ShowTip("Slot " n " 未找到: " targetTitle, 2500)
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

    app := GetApp(s.hwnd)
    if (app = "Browser") {
        CycleBrowserTabs(s.hwnd, s.title, n)
    } else if (app = "VSCode") {
        name := VSCodeFileName(s.title)
        if !name {
            ShowTip("Slot " n " 无法解析文件名", 2000)
            return
        }
        cur := WinGetTitle("ahk_id " s.hwnd)
        if (VSCodeFileName(cur) = name) {
            ShowTip("Slot " n ": " name, 1200)
            return
        }
        start := cur
        prev := cur
        ; VS Code 用 Ctrl+PageDown 顺序切换编辑器，标题会立即更新
        Loop 30 {
            SendInput "^{PgDn}"
            Sleep 60
            cur := WinGetTitle("ahk_id " s.hwnd)
            if (VSCodeFileName(cur) = name) {
                ShowTip("Slot " n " 已定位: " name, 1500)
                return
            }
            ; 绕回起点 → 当前编辑器组里没有该文件，提前结束
            if (cur = start)
                break
            ; 按键没有推进（到达末尾且不回环）→ 提前结束
            if (cur = prev)
                break
            prev := cur
        }
        ShowTip("Slot " n " 未找到: " name, 2500)
    } else {
        ShowTip("Slot " n ": " s.title, 1200)
    }
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
