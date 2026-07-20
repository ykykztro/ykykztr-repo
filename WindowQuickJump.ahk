; ============================================================
;  WindowQuickJump.ahk — 窗口/标签页编号直达工具
;  AHK v2       左Alt+1~9 绑定/切换    Ctrl+左Alt+1~9 强制覆盖
;  支持：浏览器标签页（记录标签位置 Ctrl+数字瞬跳 / 重复标题精确 / 回退翻页）/ VS Code 编辑器
; ============================================================

#Requires AutoHotkey v2.0
#MaxThreadsPerHotkey 8            ; 允许连按起多个线程，确保每次按下都能进函数并即时弹提示；
                                  ; 真正的“切标签”并发互斥由下方单飞 worker（g_workerRunning）保证，不靠线程数限制

; （已移除自动提权：本脚本仅操作窗口/剪贴板，无需管理员；提权反而引发 UAC 弹窗与权限隔离隐患）

; === 全局设置 ===
SetTitleMatchMode 2
GroupAdd "QJSelf", "ahk_class AutoHotkey"

; === 数据槽位 ===
Slot := []
Slot.Length := 9
Loop 9
    Slot[A_Index] := 0

; === 单飞 worker：快按不堆积卡顿 ===
;   每次热键只做“轻量提示 + 记录最新请求”，重跳转交给唯一一个 worker 串行执行。
;   快按 N 下 → N 条提示照常弹出，但 worker 只处理“最新”请求，标签最多翻一两次即停，
;   不会像旧版那样把每次按下都排进串行队列导致十几秒标签狂翻（看似死机）。
global g_workerRunning := false
global g_reqAction := ""      ; "jump" / "bind"
global g_reqN := 0
global g_reqSeq := 0          ; 单调递增请求序号：每次按下 +1，worker 据此判断“是否有更新的请求”

; === 浏览器窗口类名 ===
BrowserClasses := ["Chrome_WidgetWin_1", "Chrome_WidgetWin_0"]

; === 右下角轻提示（置顶 GUI，不抢焦点，小窗/全屏都可见）===
;   用屏幕坐标钉在右下角，+AlwaysOnTop 盖在最大化浏览器之上；
;   Show 带 NoActivate 且不接收输入，绝不偷走键盘焦点
;   （因此切回正在播放视频的标签页后，空格仍可直接控制视频）。
ShowTip(msg, ms := 1500) {
    static g := "", t := "", hideFn := ""
    if (!IsObject(g)) {
        g := Gui("+AlwaysOnTop -Caption +ToolWindow", "")
        g.BackColor := "1F1F1F"
        g.SetFont("s10", "Segoe UI")
        t := g.AddText("cFFFFFF w320 Center", "")
        hideFn := (p*) => g.Hide()
    }
    t.Value := msg
    g.Show("x" (A_ScreenWidth - 340) " y" (A_ScreenHeight - 80) " NoActivate")
    ; 取消上一次待执行的隐藏，只保留本次：否则快速连按时首个 timer 会在第一次按下后 ms 就 Hide，
    ; 把后续按下的提示提前藏掉，表现为“提示跟不上/闪一下就没”。
    SetTimer(hideFn, 0)
    SetTimer(hideFn, -ms)
}

; === 判断应用类型 ===
;  VS Code 与 Chrome 同属 Chrome_WidgetWin_1 窗口类，必须先按进程名区分
;  Code.exe，否则会被误判为浏览器而用错按键。
GetApp(hwnd) {
    global BrowserClasses
    ; try/catch 兜底：窗口句柄失效时 WinGetProcessName/WinGetClass 会抛错，
    ; 若直接 `try x := ...` 且抛错，x 将永远未被赋值 → 后续 `if (x = ...)` 报
    ; “This local variable has not been assigned a value”。故 catch 里给默认值。
    try proc := WinGetProcessName("ahk_id " hwnd)
    catch {
        proc := ""
    }
    if (proc = "Code.exe")
        return "VSCode"
    try cls := WinGetClass("ahk_id " hwnd)
    catch {
        cls := ""
    }
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

; === 顺序遍历（回退层：位置 >8 / URL 读取失败 / 标签漂移时兜底）===
;  发送切换键后最多等 50ms（通常 10ms 内标题即更新），读标题→看匹配→发下一键。
;  已见标题集合检测回环；正向 + 反向双圈兜底。
;  硬性上限：每方向最多 16 次切换，超出即判定“未找到”退出，避免过量重试卡顿。
CycleTabs(hwnd, key, matchesFn, keyFn, n, label) {
    if matchesFn(WinGetTitle("ahk_id " hwnd)) {
        ShowTip(label " 已定位", 1200)
        return true
    }
    seen := [keyFn(WinGetTitle("ahk_id " hwnd))]
    Loop 16 {
        SendInput key
        ; 等待标题切换（极速版：最多 50ms，通常 10ms 内完成）
        newCore := ""
        end := A_TickCount + 50
        Loop {
            cur := keyFn(WinGetTitle("ahk_id " hwnd))
            if (cur != seen[seen.Length]) {
                newCore := cur
                break
            }
            if (A_TickCount > end)
                break
            Sleep 10
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
        if (seen.Length > 16)    ; 安全上限，避免异常情况下无限累积
            break
    }
    return false
}

; === 等待窗口标题清洗后等于 name（最多 ms 毫秒）===
;  替代固定长 Sleep：标题一变即返回，跳转更跟手；超时返回 false 交由上层回退。
WaitTitle(hwnd, name, ms := 350) {
    end := A_TickCount + ms
    Loop {
        ; 前缀匹配：容忍尾部动态后缀，但避免 “News” 误命中 “Newspaper” 这类子串误判
        if (InStr(BrowserPageTitle(WinGetTitle("ahk_id " hwnd)), name) == 1)
            return true
        if (A_TickCount > end)
            return false
        Sleep 15
    }
}

; === 取得目标标签在窗口中的 1-based 位置（最多检查前 8 个，硬上限止损）===
;  用标题匹配：Ctrl+1 跳到首个标签（不回环、可靠），向后数到标题匹配即返回。
;  位置唯一，重复标题也能稳定跳到绑定位置；只读窗口标题，不碰地址栏。
;  硬性上限 8：Ctrl+数字只覆盖 1~8，超出本函数无能为力，直接返回 0 交回退层。
;  （不再 Loop 100 / pos>50，找不到时最多导航 8 次即停，杜绝过量循环）
GetTabPosition(name, hwnd) {
    SendInput "^1"           ; 跳到第一个标签（Ctrl+1 不回环，可靠）
    ; 等标题从“当前标签”真正切到“标签1”后再判定（取代固定 Sleep 60，避免读错尚未切换的标题）
    prev := BrowserPageTitle(WinGetTitle("ahk_id " hwnd))
    end := A_TickCount + 120
    Loop {
        Sleep 12
        cur := BrowserPageTitle(WinGetTitle("ahk_id " hwnd))
        if (cur != prev)
            break
        if (A_TickCount > end)
            break
    }
    Loop 8 {
        pos := A_Index
        if (InStr(BrowserPageTitle(WinGetTitle("ahk_id " hwnd)), name) == 1)
            return pos
        if (pos < 8) {
            SendInput "^{PgDn}"
            ; 轮询等标题真正变化再读（取代固定 Sleep 30，避免慢机器读错上一个标签导致漏判/错位）
            prev := BrowserPageTitle(WinGetTitle("ahk_id " hwnd))
            end := A_TickCount + 120
            Loop {
                Sleep 12
                cur := BrowserPageTitle(WinGetTitle("ahk_id " hwnd))
                if (cur != prev)
                    break
                if (A_TickCount > end)
                    break
            }
        }
    }
    return 0
}

; === 绑定当前窗口（仅记录标识，不做任何标签导航，避免首次按下抖动）===
BindWindow(n, *) {
    ; 注：本函数由 worker 定时器调用，A_ThisHotkey 为空；自动重复过滤已在
    ;     QuickJump / BindHotkey 热键入口处完成，此处不再重复判断。
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
    if (app = "Browser") {
        tabIndex := GetTabPosition(name, hwnd)   ; 绑定瞬间算位置（翻一次页，仅此一次，只读标题不碰地址栏）
        if (tabIndex >= 1)
            Slot[n] := { hwnd: hwnd, name: name, tabIndex: tabIndex }
        else
            Slot[n] := { hwnd: hwnd, name: name }
    } else
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
    if !WinWaitActive("ahk_id " s.hwnd, , 300) {   ; 确保窗口真正到前台再发快捷键，避免 Ctrl+数字被后台窗口漏收
        ShowTip("Slot " n " 窗口激活失败", 1500)
        return
    }
    Sleep 60

    app := GetApp(s.hwnd)
    if (app = "Browser") {
        name := s.name
        if (name = "") {
            ShowTip("Slot " n " 名字为空", 1500)
        } else {
            found := false
            ; ① 若已缓存位置 → Ctrl+数字 瞬跳并校验标题（最常用、最稳、零翻页、不动地址栏）
            if (s.HasOwnProp("tabIndex") && s.tabIndex >= 1 && s.tabIndex <= 8) {
                SendInput "^" s.tabIndex
                if (WaitTitle(s.hwnd, name, 300)) {
                    ShowTip("Slot " n " 已定位", 1200)
                    found := true
                }
            }
            ; ② 位置未知 → 按标题顺序定位（最多 8 步即停），成功则缓存位置供下次瞬跳
            if (!found) {
                pos := GetTabPosition(name, s.hwnd)
                if (pos >= 1 && pos <= 8) {
                    s.tabIndex := pos
                    ShowTip("Slot " n " 已定位", 1200)
                    found := true
                }
            }
            ; ③ 终极回退：标题顺序遍历（位置>8 / 漂移）
            if (!found) {
                mF(t) {
                    return InStr(BrowserPageTitle(t), name) == 1
                }
                found := CycleTabs(s.hwnd, "^{PgDn}", mF, BrowserPageTitle, n, "Slot " n)
                if !found
                    found := CycleTabs(s.hwnd, "^{PgUp}", mF, BrowserPageTitle, n, "Slot " n)
                ; 顺序查找成功 → 重算并记录位置，避免下次再走顺序查找（如关标签导致位置漂移）
                if (found) {
                    pos := GetTabPosition(name, s.hwnd)
                    if (pos >= 1 && pos <= 8)
                        s.tabIndex := pos
                }
            }
            if (!found)
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
    Hotkey "<!" n, QuickJump.Bind(n)        ; Alt+N：已绑定则跳转，未绑定则绑定
    Hotkey "^<!" n, BindHotkey.Bind(n)      ; Ctrl+Alt+N：强制覆盖绑定
}

; === 单飞 worker：每次按下只记“最新请求”，由唯一 worker 异步串行执行重跳转 ===
;   设计目标：
;   ① 即时反馈——热键里先弹提示（见下），满足“按一次反应一次”；
;   ② 不卡死——重跳转（发 Ctrl+数字、翻标签、轮询标题）全在 worker 里，同一时刻只有一个
;      worker 在跑；快按再多也只串行处理“最新”请求，不会把每次按下都排成长队狂翻标签。
StartWorker() {
    global g_workerRunning
    if (g_workerRunning)          ; worker 已在跑，会顺带处理最新请求，无需重复起
        return
    g_workerRunning := true
    SetTimer(WorkerTick, -10)     ; 异步执行，绝不阻塞热键线程
}

WorkerTick() {
    global g_workerRunning, g_reqAction, g_reqN, g_reqSeq
    ; 用单调递增序号判定“是否有更新的请求”，而非比较 (action,n)——
    ; 否则执行期间若又按下“完全相同”的 (action,n)（如先 Alt+1 绑定、紧接着 Alt+1 想跳转），
    ; 变量值未变会被误判为“无新请求”而丢弃后一次按下，违背“快按每次都有反应”。
    mySeq := g_reqSeq
    action := g_reqAction
    n := g_reqN
    try {
        if (action = "jump") {
            global Slot
            Slot[n] ? JumpToWindow(n) : BindWindow(n)
        } else if (action = "bind") {
            BindWindow(n)
        }
    }
    ; 只要序号变化（任意新按下，无论 action/n 是否相同）就再跑一轮，避免丢弃后按下的请求。
    if (g_reqSeq != mySeq)
        SetTimer(WorkerTick, -10)
    else
        g_workerRunning := false
}

QuickJump(n, *) {
    ; 屏蔽系统按键自动重复：仅响应间隔 >250ms 的物理按下，避免“重复触发”
    if (A_PriorHotkey = A_ThisHotkey && A_TimeSincePriorHotkey < 250)
        return
    ; 即时反馈：按键一触发就先弹提示（满足“快按每次都有反应”），重跳转交给 worker
    global Slot, g_reqAction, g_reqN, g_reqSeq
    s := Slot[n]
    if (s)
        ShowTip("Slot " n " → " s.name, 1000)
    else
        ShowTip("Slot " n " 待绑定", 1000)
    g_reqAction := "jump"
    g_reqN := n
    g_reqSeq++
    StartWorker()
}

BindHotkey(n, *) {
    ; 屏蔽系统按键自动重复
    if (A_PriorHotkey = A_ThisHotkey && A_TimeSincePriorHotkey < 250)
        return
    ; 即时反馈：先弹提示，重绑定交给 worker
    global g_reqAction, g_reqN, g_reqSeq
    ShowTip("Slot " n " 强制绑定中…", 1000)
    g_reqAction := "bind"
    g_reqN := n
    g_reqSeq++
    StartWorker()
}

; === 退出清理 ===
OnExit(Cleanup)
Cleanup(*) {
    ; 退出时无需重置 Slot（进程即将结束），也避免在 OnExit 中创建/显示 GUI 带来的不稳定
    return
}

; === 启动提示 ===
ShowTip("WindowQuickJump 已启动`nAlt+1~9 绑定/切换 | Ctrl+Alt+1~9 强制覆盖", 3000)
