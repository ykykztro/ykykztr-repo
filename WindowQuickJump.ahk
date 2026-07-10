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

; === 右下角轻提示（置顶 GUI，不抢焦点，小窗/全屏都可见）===
;   用屏幕坐标定位到右下角，+AlwaysOnTop 盖在最大化浏览器之上；
;   Show 带 NoActivate，且窗口本身不接收输入，绝不会偷走键盘焦点
;   （因此切回正在播放视频的标签页后，空格仍可直接控制视频）。
ShowTip(msg, ms := 1500) {
    static g := "", t := ""
    if (!IsObject(g)) {
        g := Gui("+AlwaysOnTop -Caption +ToolWindow", "")
        g.BackColor := "1F1F1F"
        g.SetFont("s10", "Segoe UI")
        t := g.AddText("cFFFFFF w320 Center", "")
    }
    t.Value := msg
    g.Show("x" (A_ScreenWidth - 340) " y" (A_ScreenHeight - 80) " NoActivate")
    SetTimer(() => g.Hide(), -ms)
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

; === 去掉浏览器标题后缀，只留"页面标题核心" ===
;  Chrome/Edge 标题形如 "页面名 - Google Chrome" / "页面名 - Microsoft Edge"。
;  去掉浏览器名后缀后做匹配，可规避 YouTube 等动态前缀(▶/⏸)的干扰。
BrowserPageTitle(title) {
    t := title
    suffixes := [" - Google Chrome", " - Microsoft Edge", " - Microsoft Edge (Chromium)"]
    for s in suffixes {
        idx := InStr(t, s)
        if idx
            t := SubStr(t, 1, idx - 1)
    }
    return Trim(t)
}

; === 把键盘焦点送回网页渲染控件（解决"停在设置和其他"）===
;  切回浏览器标签页后，焦点有时停留在 Edge ⋮ 菜单 / 标签栏，
;  导致空格无法控制网页视频。把焦点交给页面的渲染控件即可恢复。
FocusPage(hwnd) {
    try {
        ; 直接按控件名把键盘焦点送回页面渲染控件，避免视频空格失效
        ControlFocus("Chrome_RenderWidgetHostHWND1", "ahk_id " hwnd)
    } catch {
        ; 控件不存在（极少见）→ 不做处理，焦点大概率已在页面
    }
}

; === 通用标签页遍历 ===
;  key        : 用于切换的按键，如 "^{PgDn}"（正向）/ "^{PgUp}"（反向）
;  matchesFn  : 传入当前标题，返回是否已定位到目标
;  keyFn      : 提取"可比核心"（用于起点/卡住判定），如 BrowserPageTitle
;  返回 {found:bool, wrapped:bool}
;  关键点：
;   - Sleep 130：留出标签切换后标题刷新的时间（之前 60ms 太短会误判卡住）
;   - 连续两步标题无变化(same>=2)才判定到底：避免单步偶发不刷新导致误放弃
;   - 回到起点(start)判定：处理会回环的浏览器的一整圈遍历
CycleTabs(hwnd, key, matchesFn, keyFn, n, label) {
    cur := WinGetTitle("ahk_id " hwnd)
    if matchesFn(cur) {
        ShowTip(label " 已定位", 1200)
        return { found: true, wrapped: false }
    }

    start := keyFn(cur)
    prev := start
    same := 0
    wrapped := false

    Loop 30 {
        SendInput key
        Sleep 130
        cur := WinGetTitle("ahk_id " hwnd)
        if matchesFn(cur) {
            ShowTip(label " 已定位", 1500)
            return { found: true, wrapped: wrapped }
        }
        ck := keyFn(cur)
        ; 已绕回起点 → 整圈遍历完，全部标签都不匹配
        if (ck = start) {
            wrapped := true
            break
        }
        ; 连续两步标题无变化 → 已到末尾且不回环，避免空转到上限
        if (ck = prev)
            same++
        else
            same := 0
        if (same >= 2)
            break
        prev := ck
    }

    return { found: false, wrapped: wrapped }
}

; === 把浏览器/编辑器切回起始标签，避免"找不到"时把用户留在别的标签 ===
RestoreToStart(hwnd, key, startCore, keyFn) {
    cur := keyFn(WinGetTitle("ahk_id " hwnd))
    if (cur = startCore)
        return
    Loop 30 {
        SendInput key
        Sleep 130
        if (keyFn(WinGetTitle("ahk_id " hwnd)) = startCore)
            return
    }
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

    app := GetApp(s.hwnd)
    if (app = "Browser") {
        targetCore := BrowserPageTitle(s.title)
        mF := (t) => InStr(BrowserPageTitle(t), targetCore)
        kF := BrowserPageTitle
        startCore := BrowserPageTitle(WinGetTitle("ahk_id " s.hwnd))

        ; 正向遍历；若浏览器不回环("设置"等)且目标在左侧，再反向兜底
        r := CycleTabs(s.hwnd, "^{PgDn}", mF, kF, n, "Slot " n)
        if !r.found && !r.wrapped
            r := CycleTabs(s.hwnd, "^{PgUp}", mF, kF, n, "Slot " n)

        if !r.found {
            RestoreToStart(s.hwnd, "^{PgDn}", startCore, kF)
            ShowTip("Slot " n " 未找到: " targetCore, 2500)
        }
        ; 无论是否找到，都把焦点送回页面（空格可控制视频）
        FocusPage(s.hwnd)
    } else if (app = "VSCode") {
        name := VSCodeFileName(s.title)
        if !name {
            ShowTip("Slot " n " 无法解析文件名", 2000)
            return
        }
        ; 已在该文件 → 直接确认，避免弹快速打开框闪烁
        if (VSCodeFileName(WinGetTitle("ahk_id " s.hwnd)) = name) {
            ShowTip("Slot " n ": " name, 1200)
            return
        }
        ; 用 Ctrl+P 快速打开按文件名直达：不依赖标签页方向键，
        ; 不受"最近使用"顺序影响，也支持分屏/多编辑器组。
        SendInput "^p"
        Sleep 250
        SendInput "^a{Delete}"        ; 清空可能残留的输入
        Sleep 60
        SendInput name                ; 输入文件名
        Sleep 400
        SendInput "{Enter}"
        Sleep 200
        cur := WinGetTitle("ahk_id " s.hwnd)
        if (VSCodeFileName(cur) = name)
            ShowTip("Slot " n " 已定位: " name, 1500)
        else
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
    ShowTip("QuickJump 已退出", 1200)
}

; === 启动提示 ===
ShowTip("WindowQuickJump 已启动`nAlt+1~9 绑定/切换 | Ctrl+Alt+1~9 强制覆盖", 3000)
