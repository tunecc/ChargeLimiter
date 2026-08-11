# Relaxin roothide 配置持久化修复与诊断设计

## 背景

最新版 Relaxin 越狱环境安装 ChargeLimiter roothide 包后，daemon 已恢复运行，
App 也能读取电池数据，但任何设置修改都会提示：

> Save Failed
> Settings could not be saved. The previous value was restored.

本地提交 `121d30f` 为 roothide 路径解析失败增加了从自身可执行文件推导
`.jbroot-*` 根目录的 fallback。该提交意外把路径最终初始化代码移动到了
“路径解析失败”分支内部。因此，当 Relaxin 上正常解析成功时，
`g_confPath`、`g_logPath`、`g_dbPath` 和相关全局路径反而保持为空。
`CLSettingsStore.apply` 随后无法取得配置写入路径，写入失败并回滚内存值。

## 目标

1. 修复 `ensureAppPathsWithLibroot()` 的控制流回归。
2. 保证正常解析和 fallback 都经过同一个路径最终初始化出口。
3. 为 App 写盘、文件权限和 daemon 重载链路提供足够的真机诊断信息。
4. 保持 rootful、rootless、roothide 和 TrollStore 的既有存储策略。
5. 通过本地构建和真机操作验证设置确实落盘、重启后保留且被 daemon 使用。

## 非目标

- 不把配置存储重写为新的 localhost IPC 协议。
- 不迁移或重置现有用户配置。
- 不自动删除文件或递归修改共享目录权限。
- 不修改充电策略本身。
- 不进行与本故障无关的路径或设置模块重构。

## 方案比较

### 方案 A：只修复控制流

将路径最终初始化移出失败分支。改动最小，但真机若仍存在权限、路径不一致或
daemon 未重载问题，只能继续依赖笼统的保存失败提示。

### 方案 B：修复控制流并完善诊断（采用）

修复统一初始化出口，并记录 App 和 daemon 的实际配置路径、文件属性、写入结果
与重载结果。该方案直接修复已确认回归，同时让一次真机测试能够区分空路径、
权限错误、原子替换失败和 daemon 未重载。

### 方案 C：由 daemon 通过 IPC 统一写配置

App 将设置发送给 daemon，由 daemon 负责落盘。该方案能绕开 App 的共享目录写
权限问题，但会扩大改动面，并引入 IPC 一致性、错误恢复和版本兼容问题。当前
故障已有明确的本地控制流原因，因此不采用。

## 修复架构

`ensureAppPathsWithLibroot()` 按以下三个阶段执行：

1. **解析**：获取 `appDoc`、`sharedDataRoot` 和 `configRoot`。
2. **恢复**：只有任一路径为空时才进入环境对应的 fallback。roothide 从自身可执行
   文件推导 `.jbroot-*` 根；其他环境保留现有 fallback 行为。
3. **最终初始化**：在解析分支之外统一校验非空、创建目录、赋值全局路径并记录
   初始化来源。正常解析和 fallback 必须都经过这个阶段。

为避免同类缩进回归，路径赋值和目录初始化保持为一个明确、单一的代码块；不在
每个环境分支中复制赋值逻辑。

初始化成功后，既有数据流保持不变：

```text
设置界面
  -> setlocalKVChecked / CLSettingsStore.apply
  -> 共享 com.chargelimiter.mod.plist
  -> daemon reload_conf
  -> daemon 使用新配置执行充电策略
```

写盘失败时继续回滚 `CLSettingsStore` 内存值，避免 UI 将未持久化的数据显示为已保存。

## 诊断设计

诊断日志只记录元数据，不记录具体配置值。

### 路径初始化

记录以下字段：

- 进程角色：App 或 daemon
- `jbType`
- 解析来源：`libroot`、`libroothide` 或 `exe-fallback`
- PID、UID、EUID、GID、EGID
- App 数据、共享数据、配置、日志和数据库路径
- 目录创建结果及对应错误

### 配置写入

记录以下字段：

- 目标配置路径
- 序列化后的字节数
- 原子写入成功或失败
- 非原子 fallback 是否触发及其结果
- `NSError` domain/code 和相关 `errno`
- 写入后的存在状态、文件大小、修改时间、owner UID/GID 和 mode
- 写后 plist 能否重新解析

当前工作区已有的非原子写 fallback 可以保留，但其写入结果必须通过重新读取和
plist 解析校验。校验失败仍返回保存失败，不能把不完整文件当作成功。

### Daemon 重载

`reload_conf` 记录 daemon 实际读取路径、文件元数据、读取到的键数量和重载结果。
诊断报告增加“配置持久化链路”段，汇总：

- App 与 daemon 的规范化配置路径
- 两者是否指向同一文件
- 最近一次写入结果
- 最近一次 daemon 重载结果
- 配置目录和文件权限状态

复制报告时继续脱敏 `.jbroot-*` 随机标识。日志和报告不得输出配置值。

## 错误处理

1. 最终路径仍为空时，返回明确的路径解析失败，不尝试写入模糊候选路径。
2. 目录创建失败时记录完整错误，并保持现有 `Save Failed` 用户提示。
3. 原子写失败后可尝试当前已有的直接写 fallback，但必须执行写后解析校验。
4. App 与 daemon 的规范化配置路径不一致时，在诊断报告中明确标记，不静默忽略。
5. 不自动删除配置、不重置设置，也不执行递归权限修改。
6. daemon 重载失败不能反向宣称配置已生效；报告分别展示“已落盘”和“已加载”。

## 测试设计

### 本地自动验证

- 增加回归测试，确保正常解析和 fallback 两条路径都进入统一最终初始化。
- 覆盖空路径、目录创建失败、原子写失败和直接写校验失败。
- 验证诊断信息不包含具体配置值。
- 编译 rootful、rootless 和 roothide scheme。
- 运行 `./scripts/build_packages.sh` 并确认生成 roothide 安装包。
- 检查 Git 状态，确保 `ex/`、`out/` 和构建目录未被提交。

### 真机验收

第一轮使用纯 App 设置验证持久化：

1. 安装新 roothide 包。
2. 修改深色模式等纯 App 设置。
3. 确认不再出现 `Save Failed`。
4. 杀掉 App 后重开，确认设置仍保留。

第二轮验证 daemon 消费配置：

1. 修改一个 daemon 使用的充电设置。
2. 确认配置写盘成功。
3. 确认 daemon 成功执行 `reload_conf`。
4. 确认实际充电策略发生对应变化。
5. 导出诊断报告用于最终核对。

## 完成标准

- 正常路径解析时所有全局路径均非空。
- fallback 路径仍能正确初始化同一组全局路径。
- App 与 daemon 使用同一份规范化配置文件。
- 修改设置不再触发 `Save Failed`，杀掉 App 后设置仍保留。
- daemon 重载成功并使用新的充电配置。
- 写后配置可重新解析，权限状态符合共享读写要求。
- rootful、rootless、roothide 构建通过，roothide 包成功生成。
- 现有未提交的 `daemon.mm`、`utils.mm` 和 `ex/` 内容未被覆盖或误提交。
