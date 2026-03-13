# 为什么需要 Keep-Alive：macOS 合成鼠标事件的陷阱

## 问题

用 Hammerspoon 模拟鼠标按钮 4 作为 Wispr Flow 的 Push-to-Talk 触发键。按住脚踏板后，PTT 在 **1-2 秒后自动中断**，即使踏板仍然被踩住。

## 根因

macOS 对合成事件（CGEvent）和硬件事件维护**独立的状态表**：

| 状态表 | 来源 | `CGEventSourceButtonState` 可查？ |
|--------|------|----------------------------------|
| `kCGEventSourceStateHIDSystemState` | 物理硬件 | 只反映真实设备 |
| `kCGEventSourceStateCombinedSessionState` | 硬件 + 软件 | 理论上包含合成事件，实测不包含 |
| `kCGEventSourceStatePrivate` | 当前进程 | 仅本进程可见 |

**实验验证**（通过 Hammerspoon IPC）：

```
操作                                    checkMouseButtons() 结果
──────────────────────────────────────  ──────────────────────────
基线                                    {}
发送 otherMouseDown(button4)            {}  ← 状态未更新！
50ms 后再查                              {}  ← 仍然为空
发送 otherMouseUp(button4)              {}
```

对比 `flagsChanged`（修饰键）：

```
操作                                    checkKeyboardModifiers() 结果
──────────────────────────────────────  ──────────────────────────
基线                                    {}
发送 flagsChanged(ctrl=true)            { ctrl = true }  ← 状态持久！
单独再查                                 { ctrl = true }  ← 仍然保持
发送 flagsChanged(ctrl=false)           {}
```

**结论**：`flagsChanged` 会更新系统全局修饰符状态，但 `otherMouseDown` 不会更新系统按钮状态。合成鼠标事件只经过事件管道（event pipeline），**不写入任何状态表**。

## 影响

Wispr Flow 在 PTT 激活后会定期检查按钮是否仍然被按住。由于合成事件不更新状态表，检查结果为"未按住"→ PTT 中断。

## 解决方案：Keep-Alive 定时器

每 500ms 重发一次 `otherMouseDown` 事件，确保 Wispr Flow 的事件监听器持续收到"按钮按下"事件：

```lua
local function pressPTT()
    sendMouseDown()
    pttKeepAlive = hs.timer.doEvery(PTT_KEEPALIVE, sendMouseDown)
end
```

事件流对比：

```
旧方案（无 keep-alive）：
  t=0ms    otherMouseDown     ← Wispr Flow 开始 PTT
  t=1500ms                    ← Wispr Flow 检查按钮状态 → 未按住 → 停止 PTT

新方案（keep-alive）：
  t=0ms    otherMouseDown     ← Wispr Flow 开始 PTT
  t=500ms  otherMouseDown     ← keep-alive 重发
  t=1000ms otherMouseDown     ← keep-alive 重发
  t=1500ms otherMouseDown     ← Wispr Flow 持续看到按钮事件 → PTT 继续
  ...
  松开踏板  otherMouseUp       ← Wispr Flow 停止 PTT
```

## 为什么不用其他方案？

### 方案 1：改用 Right Control (flagsChanged)

`flagsChanged` 事件**确实**能更新系统修饰符状态（实验已证），所以 PTT 可以持续。这是 v1 方案。

**弃用原因**：Wispr Flow 偶尔在释放 Right Control 后不停止录音。Mouse Button 4 没有这个问题。

### 方案 2：纯 Karabiner `pointing_button`

Karabiner 的 `pointing_button` 通过 DriverKit 虚拟 HID 设备发送，在驱动层操作，状态持久。

**弃用原因**：Karabiner 的 `to` 字段在按下瞬间立即发送 `pointing_button`，无法先等 225ms 判断短/长按。`to_if_alone` 与 `pointing_button` 在 `to` 中的组合[无法正常工作](https://github.com/pqrs-org/Karabiner-Elements/issues/2417)——`to_if_alone` 的 Enter 不会触发。

### 方案 3：Karabiner `to_if_held_down` + `pointing_button`

`to_if_held_down` 对 `pointing_button` 会反复触发点击事件（down+up 循环），而非维持按住状态。不适合 PTT。

### 方案 4：`CGEventPost(kCGHIDEventTap, ...)`

理论上在 HID 层注入事件可能更新状态表。实测（[Hammerspoon #2104](https://github.com/Hammerspoon/hammerspoon/issues/2104)）与 `kCGSessionEventTap` 无差异。

## 参考

- [Hammerspoon #2104 - Global Event Queue](https://github.com/Hammerspoon/hammerspoon/issues/2104)：确认 `kCGHIDEventTap` vs `kCGSessionEventTap` 无实质区别
- [CGEventSourceStateID 文档](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid)：三种状态表的定义
- [CGEventSourceButtonState 文档](https://developer.apple.com/documentation/coregraphics/1408781-cgeventsourcebuttonstate)：查询按钮状态的 API
- [Karabiner-Elements #2417](https://github.com/pqrs-org/Karabiner-Elements/issues/2417)：`pointing_button` 与 `to_if_alone` 的兼容性
