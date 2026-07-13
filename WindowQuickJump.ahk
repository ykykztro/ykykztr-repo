; ============================================================
;  WindowQuickJump.ahk — 窗口/标签页编号直达工具
;  AHK v2       Alt+1~9 绑定/切换    Ctrl+Alt+1~9 强制覆盖
;  支持：浏览器标签页（Ctrl+Shift+A 标签搜索）/ VS Code 编辑器
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

; === 浏览器窗口类名 ===
BrowserClasses := ["Chrome_WidgetWin_1", "Chrome_WidgetWin_0"]

; === 右下角轻提示（置顶 GUI，不抢焦点，小窗/全屏都可见）===
;   用屏幕坐标钉在右下角，+AlwaysOnTop 盖在最大化浏览器之上；
;   Show 带 NoActivate 且不接收输入，绝不偷走键盘焦点
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
;  VS Code 与 Chrome 同属 Chrome_WidgetWin_1 窗口类，必须先按进程名区分
;  Code.exe，否则会被误判为浏览器而用错按键。
GetApp(hwnd) {
    global BrowserClasses
    try proc := WinGetProcessName("ahk_id " hwnd)
    if (proc = "Code.exe")
        return "VSCode"
    cls := WinGetClass("ahk_id " hwnd)
    for c in BrowserClasses {
        if (cls = c)
            return "Browser"
    }
    return "Other"
}

; === 从 VS Code 窗口标题提取当前编辑器文件名 ===
;  标题形如 "文件名.ext - 项目名 - Visual Studio Code"，取第一段并去掉 ●/* 未保存标记。
VSCodeFileName(title) {
    t := title
    idx := InStr(t, " - Visual Studio Code")
    if idx
        t := SubStr(t, 1, idx - 1)
    if InStr(t, " - ")
        t := SubStr(t, 1, InStr(t, " - ") - 1)
    else if InStr(t, " — ")
        t := SubStr(t, 1, InStr(t, " — ") - 1)
    while (SubStr(t, 1, 1) = "●" || SubStr(t, 1, 1) = "*")
        t := SubStr(t, 2)
    return Trim(t)
}

; === 干净标签页名字：去浏览器后缀 + 多标签计数 + profile名 + 媒体前缀 ===
;  Edge 多标签时标题形如：
;    "编程导航 - 一站式程序员学习交流社区 和另外 4 个页面 - 个人 - Microsoft Edge"
;  需要依次去掉：浏览器后缀 → "和另外N个页面" → profile名(Edge特有) → 媒体前缀
;  最终只留干净的页面标题 "编程导航 - 一站式程序员学习交流社区"。
BrowserPageTitle(title) {
    t := title
    isEdge := false
    suffixes := [" - Google Chrome", " - Microsoft Edge", " - Microsoft Edge (Chromium)"]
    for s in suffixes {
        idx := InStr(t, s)
        if idx {
            t := SubStr(t, 1, idx - 1)
            if (s != " - Google Chrome")
                isEdge := true
        }
    }
    ; 去掉 " 和另外 N 个页面"（Edge 多标签时自动添加，标签数变化会导致匹配失败）
    t := RegExReplace(t, " 和另外 \d+ 个\S+")
    ; Edge 标题末尾会带 profile 名（如 "- 个人"），去掉最后一段 " - xxx"
    if isEdge {
        lastDash := 0
        pos := 0
        Loop {
            pos := InStr(t, " - ", false, pos + 1)
            if !pos
                break
            lastDash := pos
        }
        if lastDash
            t := SubStr(t, 1, lastDash - 1)
    }
    ; 去掉开头的媒体状态符号(▶播放/⏸暂停/🔴直播/●录制)
    mediaSymbols := "▶⏸🔴●◼▮■"
    while (InStr(mediaSymbols, SubStr(t, 1, 1)))
        t := SubStr(t, 2)
    return Trim(t)
}

; === 页面焦点策略（IME 友好）===
;  早期版本用 ControlFocus("Chrome_RenderWidgetHostHWND1") 强行把焦点
;  交给整页渲染控件，结果把微软拼音候选框钉在了窗口左上角(0,0)——
;  因为这控件没有光标，IME 找不到合成/候选位置就回退到原点。
;  现改为：仅用 WinActivate + 键盘 Ctrl+PageDown 循环切标签，
;  Chromium 会自然把焦点保留在页面内容（空格仍可控制视频），
;  同时 IME 候选框也能正常跟随光标。故不再调用 ControlFocus。

; === 顺序遍历查找（浏览器标签页定位的主要方式）===
;  key       : 切换键，如 "^{PgDn}"(正向) / "^{PgUp}"(反向)
;  matchesFn : 传入当前标题，返回是否到达目标
;  keyFn     : 提取"可比核心"用于回环判定
;  发送切换键后轮询等待标题真正变化再读，规避读到旧标题导致提前放弃；
;  用"已见标题集合"检测回环：绕回起点即停止一整圈。
CycleTabs(hwnd, key, matchesFn, keyFn, n, label) {
    if matchesFn(WinGetTitle("ahk_id " hwnd)) {
        ShowTip(label " 已定位", 1200)
        return true
    }
    seen := [keyFn(WinGetTitle("ahk_id " hwnd))]
    Loop 30 {
        SendInput key
        ; 等待标题真正切换（最多 1200ms）
        newCore := ""
        end := A_TickCount + 1200
        Loop {
            cur := keyFn(WinGetTitle("ahk_id " hwnd))
            if (cur != seen[seen.Length]) {
                newCore := cur
                break
            }
            if (A_TickCount > end)
                break
            Sleep 25
        }
        if (newCore = "")        ; 标题始终未变 → 该方向已到头
            break
        if matchesFn(WinGetTitle("ahk_id " hwnd)) {
            ShowTip(label " 已定位", 1500)
            return true
        }
        inSeen := false
        for v in seen {
            if (v = newCore) {
                inSeen := true
                break
            }
        }
        if (inSeen)              ; 绕回起点 → 完成一整圈
            break
        seen.Push(newCore)
        if (seen.Length > 40)
            break
    }
    return false
}

; === 绑定当前窗口（存储干净的标签页名字）===
BindWindow(n, *) {
    global Slot
    hwnd := WinExist("A")
    if !hwnd || WinActive("ahk_group QJSelf") {
        ShowTip("不能绑定此窗口", 1500)
        return
    }
    title := WinGetTitle("ahk_id " hwnd)
    app := GetApp(hwnd)
    ; 存干净的"标签页名字"：浏览器去后缀/媒体前缀，VS Code 取文件名，其他用原标题
    name := (app = "Browser") ? BrowserPageTitle(title)
          : (app = "VSCode")  ? VSCodeFileName(title)
          : title
    Slot[n] := { hwnd: hwnd, name: name }
    ShowTip("Slot " n " 已绑定: " name, 2000)
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
        ShowTip("Slot " n " 窗口已关闭: " s.name, 3000)
        Slot[n] := 0
        return
    }
    WinActivate("ahk_id " s.hwnd)
    Sleep 100

    app := GetApp(s.hwnd)
    if (app = "Browser") {
        name := s.name
        mF(t) {
            return InStr(BrowserPageTitle(t), name)
        }
        if (name = "") {
            ShowTip("Slot " n " 名字为空", 1500)
        } else if (BrowserPageTitle(WinGetTitle("ahk_id " s.hwnd)) = name) {
            ShowTip("Slot " n " 已定位", 1200)
        } else {
            ; 不依赖标签搜索面板：用已清洗的名字直接顺序循环遍历标签页
            ; 正向 Ctrl+PageDown 遍历全部标签，回到起点即一圈；
            ; 若浏览器不回环且目标在左侧，再反向 Ctrl+PageUp 兜底。
            found := CycleTabs(s.hwnd, "^{PgDn}", mF, BrowserPageTitle, n, "Slot " n)
            if !found
                found := CycleTabs(s.hwnd, "^{PgUp}", mF, BrowserPageTitle, n, "Slot " n)
            if !found
                ShowTip("Slot " n " 未找到: " name, 2500)
        }
    } else if (app = "VSCode") {
        ; 只要切换到该 VS Code 窗口即算成功，不在窗口内定位到某个文件标签
        ShowTip("Slot " n " 已切换至 VS Code", 1200)
    } else {
        ShowTip("Slot " n ": " s.name, 1200)
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
