# 阈值校准指南

## 当前参数

| 参数 | 值 | 依据 |
|------|------|------|
| `HOLD_THRESHOLD` | **225ms** | TAP 最大 155ms + 70ms 余量；最小 HOLD 363ms |

## 实测数据 (2026-03-09)

**TAP 样本**（意图按 Enter）：
```
99ms, 110ms, 125ms, 143ms, 155ms
```

**HOLD 样本**（意图语音输入）：
```
188ms, 363ms, 2311ms, 2543ms, 3046ms, 3453ms, 5553ms, 10441ms
```

**分布**：
```
    TAP 分布                   HOLD 分布
    ┌──────────────┐           ┌──────────────────────────
    │ 99-155ms     │           │ 363ms - 10441ms+
    └──────┬───────┘           └───────┬──────────────────
           │                           │
           └───────── 225ms ───────────┘
                       ↑
                    阈值位置
```

225ms 在 TAP 最大值 (155ms) 和 HOLD 最小值 (363ms) 之间，两侧余量分别为 70ms 和 138ms。

## 重新校准步骤

### 1. 添加测试代码

在 `init.lua` 的常量区域后添加：

```lua
TEST_MODE = true
TestLog = {}
local pressTime = 0

local function logDuration(duration, action)
    if not TEST_MODE then return end
    table.insert(TestLog, { ms = math.floor(duration * 1000), action = action })
    hs.printf("DURATION: %dms → %s", math.floor(duration * 1000), action)
end
```

### 2. 修改事件处理器

在 keyDown 处理器中添加：
```lua
pressTime = hs.timer.secondsSinceEpoch()
```

在 keyUp 处理器中添加：
```lua
local duration = hs.timer.secondsSinceEpoch() - pressTime
logDuration(duration, pttActive and "HOLD" or "TAP")
```

### 3. 采集数据

1. 菜单栏 Hammerspoon → **Reload Config**
2. 随机踩 20+ 次（混合短踩和长按）
3. 打开 Hammerspoon Console，执行：

```lua
for i, e in ipairs(TestLog) do print(e.ms, e.action) end
```

### 4. 分析并调整

- 找出 TAP 最大值和 HOLD 最小值
- 阈值应在两者之间，偏向 TAP 一侧（TAP 最大值 + 50~100ms）
- 修改 `HOLD_THRESHOLD` 并移除测试代码
