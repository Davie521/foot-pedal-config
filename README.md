# LinTx 单键脚踏板 — macOS 双功能配置

将 LinTx USB 脚踏板配置为双功能输入设备，配合 [Wispr Flow](https://wisprflow.ai) 语音输入使用。

| 操作 | 输出 | 用途 |
|------|------|------|
| **短踩** (< 225ms) | `Enter` | 确认、提交、发送消息 |
| **长按** (≥ 225ms) | Mouse Button 4 (持续按住) | Wispr Flow Push-to-Talk |

## 一键安装

```bash
git clone https://github.com/Davie521/foot-pedal-config.git
cd foot-pedal-config
./install.sh
```

脚本会自动安装 Karabiner-Elements 和 Hammerspoon（如未安装），备份现有配置，部署新配置并重载。

## 我的本地环境

| 组件 | 版本/型号 |
|------|----------|
| 脚踏板 | LinTx USB 单键脚踏板 (~¥30) |
| macOS | Sequoia (Darwin 25.3.0) |
| Karabiner-Elements | 15.9.0 |
| Hammerspoon | 1.1.1+ |
| 语音输入 | [Wispr Flow](https://wisprflow.ai) (PTT 模式) |

## 系统架构

```
┌──────────────┐         ┌────────────────────┐         ┌──────────────────────┐
│  LinTx 脚踏板 │  F4     │ Karabiner-Elements │  F19    │    Hammerspoon       │
│  (硬件)       │ ──────▶ │ 设备级按键映射      │ ──────▶ │  时长判断 + 鼠标模拟  │
│              │ keycode  │ 仅对此设备生效      │ keycode │                      │
└──────────────┘  118     └────────────────────┘   80    └──────────────────────┘
                                                              │
                                                     ┌───────┴────────┐
                                                     │                │
                                                < 225ms           ≥ 225ms
                                                     │                │
                                                  Enter       Mouse Button 4
                                                (单次按键)   (持续按住 + keep-alive)
```

### 为什么需要两层？

| 层 | 职责 | 不能省略的原因 |
|----|------|---------------|
| **Karabiner-Elements** | 设备隔离：仅拦截脚踏板的 F4，转为 F19 | Hammerspoon 无法按设备过滤按键 |
| **Hammerspoon** | 按压时长判断 + 鼠标按钮模拟 + keep-alive | Karabiner 无法同时实现短/长按区分和持续鼠标按钮状态（[详见技术分析](docs/why-keep-alive.md)） |

## 手动安装

如果不想用一键脚本，可以手动安装：

```bash
brew install --cask karabiner-elements hammerspoon
cp karabiner.json ~/.config/karabiner/karabiner.json
cp init.lua ~/.hammerspoon/init.lua
```

然后：

1. 点击菜单栏 Hammerspoon 图标 → **Reload Config**
2. 在 Wispr Flow Settings 中将 PTT 触发键设为 **Mouse Button 4**
3. 授予 Hammerspoon **Accessibility** 和 **Input Monitoring** 权限（System Settings → Privacy & Security）

## 硬件信息

| 属性 | 值 |
|------|------|
| 设备名称 | LinTx Keyboard |
| vendor_id | 32904 |
| product_id | 21 |
| 物理按键 | F4 (keycode 118) |
| 中间映射 | F19 (keycode 80) |

可在 Karabiner EventViewer 中验证。

## 配置文件

### karabiner.json

拦截 LinTx 设备的 F4，转为 F19。其他键盘不受影响。

```json
{
    "from": { "key_code": "f4" },
    "to": [{ "key_code": "f19" }],
    "conditions": [{
        "identifiers": [{ "product_id": 21, "vendor_id": 32904 }],
        "type": "device_if"
    }]
}
```

### init.lua

核心逻辑：

1. **F19 keyDown** → 启动 225ms 计时器
2. **< 225ms keyUp** → 取消计时器，发送 Enter
3. **≥ 225ms** → 激活 PTT（Mouse Button 4 Down + keep-alive 定时器）
4. **keyUp** → 停止 keep-alive，发送 Mouse Button 4 Up

**Keep-alive 机制**：每 500ms 重发 `otherMouseDown`，解决合成鼠标事件不维持系统按钮状态的问题。详见 [docs/why-keep-alive.md](docs/why-keep-alive.md)。

## 状态机

```
                           keyDown (F19)
          ┌──────────────────────────────────────┐
          │                                      ▼
     ┌─────────┐                          ┌─────────────┐
     │         │     225ms timer fires     │   PTT_HELD  │
     │  IDLE   │ ────────────────────────▶ │  + keep-    │
     │         │     pressPTT()            │    alive     │
     └─────────┘                          └─────────────┘
          ▲                                      │
          │                                      │
          │  keyUp (< 225ms)              keyUp  │
          │  → send Enter                        │
          │                              releasePTT()
          │                                      │
          └──────────────────────────────────────┘
```

| 变量 | 类型 | 含义 |
|------|------|------|
| `f19Down` | boolean | F19 是否按下 |
| `holdTimer` | timer/nil | 225ms 判定计时器 |
| `pttActive` | boolean | PTT 是否激活 |
| `pttKeepAlive` | timer/nil | 500ms keep-alive 定时器 |
| `safetyTimer` | timer/nil | 120s 安全阀 |

## 安全机制

| 风险场景 | 防护 |
|----------|------|
| OS key repeat | `if f19Down then return true` 丢弃重复 keyDown |
| 多余 keyUp | `if not f19Down then return true` 忽略 |
| Hammerspoon reload 时 PTT 卡住 | `hs.shutdownCallback → cleanup()` |
| keyUp 丢失 | 120s 安全阀自动 `cleanup()` |
| eventtap 被 macOS 禁用 | 5s watchdog 自动重启 |
| 睡眠/锁屏后 eventtap 或 timer 僵尸 | 自动 reload（覆盖系统唤醒、屏幕唤醒、解锁、用户切换） |

## 阈值校准

当前阈值 **225ms** 基于实测数据：

- TAP 样本（意图 Enter）：99ms ~ 155ms
- HOLD 样本（意图语音）：363ms ~ 10441ms
- 225ms 在两个分布之间留有 ≥70ms 余量

如需重新校准，参考 [docs/calibration.md](docs/calibration.md)。

## 故障排查

| 症状 | 原因 | 解决 |
|------|------|------|
| 踏板完全无反应 | Karabiner 未运行 | 检查菜单栏图标 |
| 终端收到 `[57382u` 乱码 | F19 未被 Hammerspoon 拦截 | Reload Config；检查辅助功能权限 |
| 短踩无 Enter | Hammerspoon 配置未加载 | Reload Config |
| PTT 1-2 秒后中断 | 缺少 keep-alive 或睡眠/锁屏后状态僵尸 | 确认使用最新 init.lua；手动 Reload Config 立即恢复 |
| PTT 卡住不释放 | keyUp 丢失 | 等 120s 安全阀；或再踩一次 |

## 版本历史

| 日期 | 变更 |
|------|------|
| 2026-03-21 | 扩展生命周期 reload：覆盖屏幕唤醒、解锁、用户切换，修复睡眠/锁屏后 PTT 1 秒断开 |
| 2026-03-13 | 从 Right Control 切换到 Mouse Button 4；新增 keep-alive 解决合成事件状态不持久问题 |
| 2026-03-09 | 初始版本：F4 → F19 → Right Control/Enter |
