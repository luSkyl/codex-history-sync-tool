# Codex History Sync Tool

一个用于恢复 Codex Desktop 本地历史对话显示的小工具。

当你切换 API、provider、模型或登录方式之后，Codex Desktop 有时会出现“本地历史明明还在，但侧边栏看不到”的情况。这个工具会检查本机的本地历史数据库和 rollout 元数据文件，并把旧线程重新挂到当前正在使用的 `model_provider` / `model` 下面。

如果你当前使用的是 Codex 官方账号，`config.toml` 里可能没有 `model_provider`。这种情况下工具会把当前目标显示为“官方账号 / 无 provider”，并使用双向 Provider Profile 处理同步：同步到官方账号时使用 `official_providerless` 形态，SQLite 按 schema 写入 `NULL` 或空字符串，rollout `session_meta` 删除 `model_provider` 字段；同步到第三方 provider 时使用 `named_provider` 形态，SQLite 和 rollout 都写入目标 provider 字符串。

## 这个工具能做什么

- 查看当前本机 Codex 历史线程属于哪些 provider
- 查看当前本机 Codex 历史线程属于哪些 model
- 查看 SQLite 和 rollout 元数据是否不一致
- 显示当前目标 Provider Profile，区分 `named_provider` 和 `official_providerless`
- 列出可找回的旧 provider / model 会话，按 Codex 会话活动时间倒序排列
- 图形界面会同时展示当前 provider / model 会话，但这些当前会话只读展示、不可勾选同步
- 图形界面一次最多加载 1000 个可找回会话，默认勾选最新 20 个
- 把选中的旧会话同步到当前设置，同时同步匹配线程的 rollout `session_meta`
- 把任意选中的会话移入可恢复回收站
- 按天数预览或清理老会话
- 从最新或指定回收站快照恢复误删会话
- 在同步前自动创建数据库和受影响 rollout 文件快照
- 从备份快照恢复数据库和 rollout 文件
- 提供一个可直接点击的 Windows 图形界面

## 适用场景

- 你切换了不同 API
- 你切换了不同 provider
- 你切换了不同模型
- 你切换了登录方式
- 你从第三方 provider 切回官方账号，而官方账号配置没有 `model_provider`
- 你从官方账号切回第三方 provider，需要把官方账号形态的本地会话挂到当前 provider
- 你确认本地历史文件还在，但 Codex Desktop 左侧历史列表变空了

## 不适用的场景

- 云端账号之间的聊天记录互相同步
- 本地历史文件已经被删除
- 不同电脑之间迁移聊天记录

## 运行环境

- Windows
- PowerShell 5.1 或更高版本
- 已安装 Python 3.10 或更高版本，并可通过 `py -3` 调用
- 本机存在 Codex Desktop 本地数据目录，通常是 `%USERPROFILE%\\.codex`

## 快速使用

### 图形界面

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launch_ui.ps1
```

### 创建桌面快捷方式

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launch_ui.ps1 -InstallShortcutOnly
```

### 查看当前状态

```powershell
py -3 .\sync_backend.py --json status
```

### 查看可找回会话

```powershell
py -3 .\sync_backend.py --json list-candidates --limit 1000
```

如果不传 `--limit`，默认也会返回最多 1000 条。返回结果优先按 rollout 会话文件的最后修改时间倒序排列，尽量跟 Codex 会话列表的顺序保持一致；没有对应 rollout 文件时再退回 SQLite 会话时间。

图形界面会使用 `--include-current` 展示完整会话视图：旧 provider / model 会话标记为“可同步”，当前 provider / model 会话标记为“当前”并禁止勾选。

### 同步最新 20 个可找回会话

```powershell
py -3 .\sync_backend.py --json sync --latest 20
```

### 同步指定会话

```powershell
py -3 .\sync_backend.py --json sync --thread-id <thread-id>
```

### 执行全量同步

```powershell
py -3 .\sync_backend.py --json sync
```

全量同步会同步所有当前可找回会话，不受图形界面“当前列表最多 1000 条”的显示上限影响。

### 预览老会话清理

```powershell
py -3 .\sync_backend.py --json trash --older-than-days 90 --dry-run
```

### 清理 90 天前的老会话

```powershell
py -3 .\sync_backend.py --json trash --older-than-days 90
```

清理不会永久删除，会把 SQLite 会话记录和对应 rollout 文件移入 `%USERPROFILE%\.codex\history_sync_trash`，并在操作前自动创建安全备份。

### 删除指定会话

```powershell
py -3 .\sync_backend.py --json trash --thread-id <thread-id>
```

图形界面也支持删除任意对话：在会话列表中勾选或点选一行/多行，然后点击“删除选中行”。复选框可用于批量删除任意会话；同步时会自动只使用其中“可同步”的会话，当前会话即使被勾选也不会参与同步。

### 查看与恢复回收站

```powershell
py -3 .\sync_backend.py --json list-trash
py -3 .\sync_backend.py --json restore-trash
py -3 .\sync_backend.py --json restore-trash --trash <trash-snapshot-path>
```

### 手动创建备份

```powershell
py -3 .\sync_backend.py --json backup
```

### 从最新备份恢复

```powershell
py -3 .\sync_backend.py --json restore
```

### 运行测试

```powershell
py -3 -m unittest discover -s tests -v
```

## 备份说明

- 每次同步前都会自动创建一份快照，包含 `state_5.sqlite` 和本次会改写的 rollout 文件
- 每次删除前都会自动创建一份安全快照，并额外创建一份可恢复回收站快照
- 手动备份会创建一份完整快照，包含 `state_5.sqlite` 和当前可发现的 rollout 文件
- 每次恢复前也会先创建一份安全快照
- 旧版本生成的 `state_5.sqlite.*.bak` 仍可恢复，但它们只包含数据库，不包含 rollout 文件
- 备份默认保存在 `%USERPROFILE%\\.codex\\history_sync_backups`
- 回收站默认保存在 `%USERPROFILE%\\.codex\\history_sync_trash`

## 使用建议

- 执行同步或恢复前请先关闭 Codex Desktop；如果 Codex 同时运行，它可能继续写入数据库，导致同步不完整或恢复结果被覆盖
- 图形界面默认加载最多 1000 个会话行，按 Codex 会话活动时间倒序排列；默认不勾选任何会话，需要手动点击“默认最新20”或自行选择
- 图形界面的“全选最多1000”只会勾选当前列表里已经加载出来的会话；如果你的可找回会话超过 1000 条，请用命令行 `py -3 .\sync_backend.py --json sync` 执行全量同步
- 只想同步最近一批时，可以用命令行 `py -3 .\sync_backend.py --json sync --latest N`，例如 `--latest 50`
- 如果同步完成后历史列表没有立刻刷新，重开一次 Codex Desktop 即可
- 官方账号模式下看到“当前 Provider”为“官方账号 / 无 provider”是正常的；这表示工具会按官方账号的无 provider 元数据格式同步，而不是写入一个伪 provider 名称。
- 第三方 provider 模式下，官方账号形态的本地会话（SQLite `NULL`/空字符串，或 rollout 缺少 `model_provider`）会被识别为可同步，并写回当前 provider 字符串。
- 当前账号切换后仍在活动的会话会被视为“当前”并禁止同步；这是为了避免把本账号下的新会话误当成旧 provider 会话迁移。
- 新版 Codex Desktop 可能会同时参考 `state_5.sqlite` 和 `sessions` / `archived_sessions` 下的 `rollout-*.jsonl`。本工具会按线程 ID 匹配 rollout 的 `session_meta.payload.id`，只改对应的 `session_meta` 和结构化 `turn_context` 里的 provider/model 元数据，不改聊天正文事件。
- 新版 Codex 可能还会按当前项目目录显示历史。如果同步后仍然看不到旧对话，先确认是否打开了旧对话原来的项目目录；本工具默认不会批量改写线程的 `cwd` 项目归属。

## 项目文件

- `sync_backend.py`：后端同步、备份、恢复逻辑
- `launch_ui.ps1`：Windows 图形界面

## 免责声明

这个工具直接操作本机 Codex 的本地状态数据库。虽然已经做了自动备份，但仍建议你在使用前先理解它的作用，并自行确认本地数据目录状态。
