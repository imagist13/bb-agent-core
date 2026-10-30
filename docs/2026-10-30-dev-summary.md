# 2026-10-30 开发总结：bbcore 垂直化、默认助手与重新打包

范围：`bb-agent-core`（`bbcore`，Rust 后端）与 `bb-studio`（Electron 壳）。

本文只记录已经实际验证的结果；没有运行或没有验证的项目在「已知限制」中明确列出。

## 1. 目标

把 fork 自 AionCore / AionUi 的工作台改造成 Buckyball 项目的垂类 agent：

- 内核只服务 bb 项目，不再携带 officecli 的助手与技能；
- 默认助手是 `buckyball`，提示词、技能、MCP 按 bb 的工作流组织；
- UI 中内置引擎的显示名从 `aion cli` 改为 `bbdev`。

## 2. 交付内容

| # | 内容 | 状态 |
| --- | --- | --- |
| 1 | 内部 crate 统一为 `bb-*` 前缀（共 26 个） | ✅ |
| 2 | 移除 9 个 officecli 技能、10 个 office 助手 | ✅ |
| 3 | 17 个 bb 技能打包进二进制 | ✅ |
| 4 | `buckyball` 中/英提示词重写 | ✅ |
| 5 | `buckyball` 成为首次启动默认助手 | ✅ |
| 6 | 修复损坏的 Rust 工具链并构建 `bbcore` release | ✅ |
| 7 | 用 bun 重新构建前端 `out/` | ✅ |

### 2.1 后端垂直化

- **crate 命名**：`crates/` 下 26 个 crate 统一为 `bb-*`（如 `bb-ai-agent`、`bb-app`、`bb-assistant`、`bb-conversation`、`bb-team`），不再保留 `aionui-*` 命名。
- **助手清单**：`crates/bb-app/assets/builtin-assistants/assistants.json` 现在有 12 个助手，只有 2 个默认启用：
  - `buckyball`（`sort_order = 0`，17 个技能）；
  - `bb-assistant`（`sort_order = 10`，3 个 BBUI 维护技能）。
  
  其余 10 个上游助手 `default_enabled` 均为 `false`，不再出现在默认工作流里。
- **bb 技能**：`crates/bb-app/assets/builtin-skills/` 下的 17 个技能全部挂到 `buckyball`：
  `ball-align`、`check`、`chip-designer`、`debug-bemu`、`debug-compiler`、`debug-p2e`、
  `debug-performance`、`debug-verilator`、`domain-modeling`、`graph-contract`、`ip-designer`、
  `model-optimize`、`model-port`、`programming-principles`、`repo-install`、`waveform`、
  `workload-tests`。
- **MCP**：`bbdev`（构建 / workload / 仿真 / 综合）与 `waveform`（波形分析），运行时经
  `bbcore config mcp servers` 注册。
- **显示名**：内置引擎在 UI 中显示为 `bbdev`。
  - `crates/bb-common/src/enums.rs:40`：`AgentType::Aionrs => "bbdev"`；
  - `crates/bb-db/migrations/045_rename_builtin_agent_to_bbdev.sql`：把数据库中的内置 agent 行改名为 `bbdev`。

### 2.2 `buckyball` 提示词

重写了两个语言版本，替换掉上游的 40 行通用摘要：

- `crates/bb-app/assets/builtin-assistants/rules/buckyball.en-US.md`（103 行）
- `crates/bb-app/assets/builtin-assistants/rules/buckyball.zh-CN.md`（81 行）

结构参考 `bbos` 的 agent 提示词，但身份与事实全部按本仓库重新核对：

1. 身份：bb-agent，Buckyball DSA 框架（RISC-V/RVV 前端、Ball 契约、`mesh_shm`），框架用 Chisel/Scala；
2. 工作对象：Ball / Core / Chip / `mesh_shm`，文档化的 C 测试是功能基准；
3. 六条硬性规则：流水线门控、新 Ball 只进 `toy`、一律走 `bbdev_*` 并轮询 `trace_id`、不允许静默恢复、尊重归属边界、不改 `arch/src/main/scala/framework/`；
4. 技能路由表：13 类任务到对应 skill；
5. 工作方式与沟通约定（先给结果、修根因、不为过门控改测试）；
6. Windows/PowerShell 平台差异说明。

注入路径：`crates/bb-ai-agent/src/factory/aionrs.rs:57-90` 把助手规则合并进
`overrides.system_prompt`，再把技能索引合并进同一字段；aionrs 把它作为
`build_system_prompt` 的 `custom_prompt` 段。规则文件通过 `include_dir!` 在编译期打进
`bbcore`，改规则只需要重新编译，不需要数据库迁移。

### 2.3 `buckyball` 成为默认助手

两层同时修改：

#### 后端排序（manifest 拥有 `sort_order`，无需迁移）

- `buckyball`：`5 → 0`
- `bb-assistant`：`0 → 10`

`sort_order` 与 `default_enabled` 都由运行时从 manifest 读取
（`crates/bb-assistant/src/service.rs:2551` 的 `builtin_listing_default`），所以不需要数据库迁移。

#### 前端选择逻辑（3 个文件）

- `bb-studio/packages/desktop/src/common/types/agent/assistantTypes.ts`
  - 新增 `PRODUCT_DEFAULT_ASSISTANT_ID = 'buckyball'`；
  - 新增 `isProductDefaultAssistant()`，兼容历史上的 `builtin-` 前缀。
- `bb-studio/packages/desktop/src/renderer/pages/guid/hooks/useGuidAssistantSelection.ts`
  - `pickDefaultAssistantSelectionKey()` 优先级改为：
    产品默认 → 生成的 aionrs 助手 → 任意 aionrs 助手 → 第一个可用助手。
- `bb-studio/packages/desktop/src/renderer/utils/model/assistantSelection.ts`
  - `selectableAssistants()` 通过 `pinProductDefaultFirst()` 把产品默认固定在第一位，
    避免被裸 CLI 助手挤到「更多」弹层里。

边界行为：

- 用户手动选过助手时，`guid.lastAssistantId` 仍然优先于新默认；
- 用户把 `buckyball` 禁用（overlay `enabled = 0`）时，它不会被选为默认；
- 已存在的会话保留创建时的助手快照，改默认只影响新会话。

### 2.4 构建链修复与重新打包

#### Rust 工具链修复

构建一开始失败：

```text
error: only metadata stub found for `rlib` dependency `core`
error: cannot resolve a prelude import
error[E0463]: can't find crate for `serde_json`
```

根因是两个 toolchain 的 sysroot 都缺少 `libcore-7c4a4c66f69609a4.rmeta`（`rustup` 自己也认为该文件应存在）。`static.rust-lang.org` 不可达，改用 rsproxy 镜像：

- 下载 `rust-std-1.95.0-x86_64-pc-windows-msvc.tar.gz`（dist 日期 `2026-04-16`）；
- 校验 SHA256 `aa56f95b4817f562c0ada0abee3511a802a948303404e8fc872d0371ae0693fc`；
- 从组件包中取出缺失的 `libcore-*.rmeta`，补进 `1.95.0` 与 `stable` 两个 toolchain；
- 用最小程序验证 `rustc +1.95.0` 与 `rustc +stable` 均可正常编译运行。

#### 后端产物

```text
cargo build --release -p bb-app
```

- 退出码 0，耗时 2m44s；
- 产物 `target/release/bbcore.exe`：95,373,312 字节，`2026-10-30 17:24:27`；
- SHA256 `9D72FB8EBE5164A94DFF41568B382845B9EF3F3B80C509583D51A93650954938`；
- 已覆盖安装到 `C:\Users\赵雷\.cargo\bin\bbcore.exe`（壳通过 `BB_BACKEND_BIN` 指向这里），源和目标哈希一致。

#### 前端产物

bun 不在 `PATH`，实际安装为 npm 全局包（`%APPDATA%\npm\bun.cmd`，版本 1.4.4）。

```text
bun run package
```

- 退出码 0，42.43s，只有 chunk 体积警告（原有问题，不是错误）；
- `out/main`、`out/preload` 更新到 17:31:40，`out/renderer`、`out/index.html` 更新到 17:32:23；
- 在 `out/renderer/assets/index-DPQUtZqA.js` 中能查到 `buckyball` 常量，确认默认助手逻辑进入产物。

## 3. 验证记录

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| TypeScript 类型检查 | `tsc -p tsconfig.json --noEmit` | 退出码 0 |
| 前端格式检查 | `oxfmt --check`（3 个改动文件） | 通过 |
| 后端 release 构建 | `cargo build --release -p bb-app` | 退出码 0 |
| 前端构建 | `bun run package` | 退出码 0 |
| 产物自检 | 在 bundle 中检索 `buckyball` | 命中 |
| Rust 单测 | `cargo test -p bb-assistant -p bb-db -p bb-common` | 见下方「测试结果」 |

### 测试结果

```text
cargo test -p bb-assistant -p bb-db -p bb-common
```

- 退出码 0；
- 44 个测试二进制全部通过，共 **986 passed / 0 failed**；
- 其中 `bb-assistant` 111、`bb-common` 97 + 20、`bb-db` 369，其余为 `bb-db` 的迁移与集成测试。

## 4. 已知限制

- **已有用户不会自动切换**：保存过 `guid.lastAssistantId` 的用户保持原选择，除非清掉该配置；
- **旧会话不换助手**：会话创建时写入 `AssistantSnapshot`，改默认只影响新会话；
- **没有打安装包**：本次只构建了 `bbcore.exe` 与 `out/`，没有走 `electron-builder`（`npm run dist:win`）；
- **aionrs 仍是外部依赖**：内置引擎仍来自 `iOfficeAI/aionrs` 的 git tag `v0.2.11`，没有 fork；
- **Windows 平台提示**：技能里的命令示例按 macOS/Linux 编写，提示词已要求模型先转成 PowerShell。

## 5. 下一步

1. 跑完整 workspace 测试（`just test`）和 `just check`；
2. 如需分发给其他人，再补 `npm run dist:win` 安装包；
3. aionrs 的二次开发准备见 [aionrs-fork-plan.md](aionrs-fork-plan.md)。
