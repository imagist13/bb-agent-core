# aionrs 二开准备：把内置引擎变成 bb 的默认 agent

> 引用基准：`iOfficeAI/aionrs` tag `v0.2.11`，commit `8e61a90`（`Cargo.lock` 中的 git rev）。
> 文中所有行号都基于该版本；升级 aionrs 后需要重新核对。

## 0. 结论

- 目前 aionrs 以内嵌方式工作：`bbcore` 进程内构建 `AgentEngine`，UI 中显示为 `bbdev`；
- **大多数 bb 定制不需要 fork**：助手规则、技能目录、MCP、子进程环境、工具白名单、运行期追加原生工具，现有扩展点都能覆盖；
- **需要 fork 的是「引擎固定行为」**：系统提示词结构、`ToolSearch` 索引时机、同名工具覆盖、turn 循环与事件协议、内置工具语义；
- 建议的顺序是：先把现有扩展点用满，出现第一个「必须改内部行为」的需求时再 fork。本文第 5 节给出 fork 后的最小改动路线。

## 1. 现状

### 1.1 依赖形态

`bb-agent-core/Cargo.toml:66-71` 直接依赖 6 个 aionrs crate，全部固定到 git tag：

```toml
aion-agent     = { git = "https://github.com/iOfficeAI/aionrs.git", tag = "v0.2.11" }
aion-providers = { ... }
aion-types     = { ... }
aion-protocol  = { ... }
aion-config    = { ... }
aion-mcp       = { ... }
```

`aion-agent` 还会传递引入 `aion-compact`、`aion-memory`、`aion-skills`、`aion-tools`、`aion-process`。
`Cargo.lock` 中实际进入依赖图的 `aion-*` 包共 11 个（`aion-cli` 不在其中）。

### 1.2 现有集成层

| 职责 | 位置 |
| --- | --- |
| 构建引擎 | `crates/bb-ai-agent/src/manager/aionrs/agent.rs:222` `AgentBootstrap::new(config, &workspace, sink).runtime_env(runtime_env)`，可选 `.resume(session)`，`:234` `.build()` |
| 助手规则注入 | `crates/bb-ai-agent/src/factory/aionrs.rs:57-90`：规则先写入 `overrides.system_prompt`，再合并技能索引 |
| 技能索引合并 | `crates/bb-ai-agent/src/factory/aionrs.rs:40` `merge_skill_index_into_system_prompt` |
| 额外 MCP | `crates/bb-ai-agent/src/factory/aionrs.rs:94`、`:852` `resolve_mcp_servers` |
| 会话配置 | `crates/bb-ai-agent/src/factory/aionrs.rs:190-205`（`system_prompt`、`session.enabled`、`session.directory`） |
| 显示名 | `crates/bb-common/src/enums.rs:40` `AgentType::Aionrs => "bbdev"` |

也就是说，bb 目前对 aionrs 的定制集中在 **bootstrap 之前**：把规则、技能、MCP 拼进 `Config`。

## 2. 现有扩展点（已核实）

| 需求 | 现有入口 | 位置 | 边界 |
| --- | --- | --- | --- |
| 指定 Provider | `AgentBootstrap::provider` | `crates/aion-agent/src/bootstrap.rs:116` | 只作用于本次 bootstrap |
| 恢复会话 | `AgentBootstrap::resume` | `bootstrap.rs:122` | `Session` 结构由 aionrs 定义 |
| 注入子进程环境 | `AgentBootstrap::runtime_env` | `bootstrap.rs:128` | 作用于工具 / hooks / MCP 子进程 |
| 工具白名单 | `AgentBootstrap::tool_policy` | `bootstrap.rs:134` | 按工具名过滤，同时影响系统提示词中的工具说明 |
| 追加技能目录 | `AgentBootstrap::extra_skill_dirs` | `bootstrap.rs:140` | 技能仍需符合 aionrs 的 SKILL.md 格式 |
| 自定义提示词 | `Config.system_prompt` | 作为 `custom` 段插入：`context.rs:266-270` | 只能**追加**，不能删除或改写固定的 intro 与 tool guidance |
| 运行期追加工具 | `AgentEngine::registry_mut` + `ToolRegistry::register` | `engine.rs:362`、`aion-tools/src/registry.rs:19` | 只能新增；工具定义每轮重算（`engine.rs:683`） |
| 原生工具实现 | `aion_tools::Tool` trait | `aion-tools/src/tool.rs:44` | 可以自定义工具，但不能覆盖同名内置工具（见 3.3） |
| 工具搜索 | `register_tool_search` | `bootstrap.rs:360` | 索引在 bootstrap 时一次性快照 |

### 2.1 一个已经验证过的细节

`ToolRegistry` 是 `Vec<Box<dyn Tool>>`，`register` 直接 push，`get` 返回**第一个**同名工具
（`aion-tools/src/registry.rs:19,26`）。因此：

- 追加一个不同名的新工具：可行；
- 用同名工具替换内置工具：不可行——`ToolSearch` 与工具定义会看到两个同名项，`ToolPolicy` 又按名字统一放行/拒绝。

这属于「需要 fork」的典型场景。

## 3. 固定行为（不改 aionrs 做不到）

### 3.1 构建顺序

`bootstrap.rs:151` 的 `build()` 固定为：

```text
builtin tools → MCP → skills → system prompt → agent tools → plan tools → ToolSearch → engine
```

没有 hook 可以改变顺序或跳过某一步。

### 3.2 系统提示词结构

`context.rs:241-331` 按固定顺序拼装：

```text
intro → tool guidance → custom prompt → AGENTS.md → memory → TOON → plan mode → skills
```

其中 intro（模型、工作目录、日期、OS、shell）与 tool guidance 是硬编码的；`custom_prompt`
只能插在中间。如果 bb 需要「换掉 intro」或「不要通用 tool guidance」，必须 fork。

另外，提示词在 bootstrap 时构建并写入 `config.system_prompt`（`bootstrap.rs:275`），
一个会话内不会重新计算。

### 3.3 ToolSearch 索引时机

`register_tool_search` 在 bootstrap 末尾对当前 registry 做一次快照
（`bootstrap.rs:360-363`）。之后通过 `registry_mut()` 追加的工具：

- 会出现在每轮的工具定义里（`engine.rs:683`）；
- **不会**出现在 `ToolSearch` 的索引里。

如果 bb 依赖「运行期注册工具 + ToolSearch 检索」的组合，需要 fork 或改上游。

### 3.4 其他

- 内置工具语义（Read/Write/Edit/ExecCommand/Grep/Glob/ViewImage，`bootstrap.rs:207-230`）；
- turn 循环、工具轮次编排与事件协议（`engine.rs`）；
- 会话序列化格式（`aion-types`）。

这些如果只是「加一层 bb 的包装」，可以放在 `bb-ai-agent` 里；一旦要改语义本身，就必须 fork。

## 4. 什么时候真的需要 fork

满足任意一条再 fork：

1. 需要改写 / 删除 aionrs 的系统提示词固定段（intro、tool guidance、skills 段格式）；
2. 需要运行期注册的工具参与 `ToolSearch`；
3. 需要覆盖同名内置工具；
4. 需要修改 turn 循环、工具并发/审批语义或事件协议；
5. 需要内置工具的新行为，且无法通过新增工具解决。

如果只是「bb 的规则、技能、MCP、模型、环境变量」，保持现状。

## 5. 二开路线（决定 fork 后）

### 5.1 仓库与分支

- 以 `v0.2.11`（`8e61a90`）为基点建 fork，例如 `DangoSys/aionrs`；
- 保留 `upstream` remote 指向 `https://github.com/iOfficeAI/aionrs.git`；
- bb 的改动放在 `bb/main` 分支，打 tag `v0.2.11-bb.1`；
- 保留 Apache-2.0 的 `LICENSE` 与版权声明。

### 5.2 依赖接入

推荐用源码内嵌 + `[patch]`，这样 `bb-agent-core` 的依赖声明保持不变：

```toml
[patch."https://github.com/iOfficeAI/aionrs.git"]
aion-agent     = { path = "thirdparty/aionrs/crates/aion-agent" }
aion-providers = { path = "thirdparty/aionrs/crates/aion-providers" }
aion-types     = { path = "thirdparty/aionrs/crates/aion-types" }
aion-protocol  = { path = "thirdparty/aionrs/crates/aion-protocol" }
aion-config    = { path = "thirdparty/aionrs/crates/aion-config" }
aion-mcp       = { path = "thirdparty/aionrs/crates/aion-mcp" }
```

注意：

- 传递依赖（`aion-tools`、`aion-skills`、`aion-memory`、`aion-compact`、`aion-process`）也会被
  path 版本替换，所以 `thirdparty/aionrs` 必须是完整 workspace；
- `scripts/just/update-aionrs.*` 目前按 git tag 升级，fork 后要改成「同步上游 + 重放补丁」的流程。

### 5.3 第一批改动（最小集，按优先级）

1. **提示词段落钩子**：让 bootstrap 接受「替换 / 删除某一段」的配置，而不是只追加 custom 段；
2. **ToolSearch 重建**：`registry_mut()` 之后能显式重建索引，或让 `ToolSearch` 每次查询时读取当前定义；
3. **同名工具覆盖**：`register` 遇到同名时替换，而不是追加；
4. 以上每项都补单元测试（aionrs 已有 `bootstrap_test.rs` 可参考）。

第 1、2 项也值得先向上游提 PR：如果被接受，可以显著减少长期分叉面积。

### 5.4 上游同步

- 固定节奏 `git fetch upstream --tags && git rebase upstream/main`；
- 维护 `PATCHES.md`：每条分叉记录「文件、原因、对应上游 issue/PR、移除条件」；
- 优先把通用改动推回上游，bb 专有的保持最小。

### 5.5 测试与验收

| 层级 | 内容 |
| --- | --- |
| aionrs 单元测试 | `cargo test -p aion-agent`（含 `bootstrap_test.rs`） |
| 提示词快照 | 对 `buckyball.zh-CN/en-US` 生成最终系统提示词并快照，fork 前后对比 |
| bb 集成测试 | 会话创建、技能注入、MCP 连接、工具调用 |
| 冒烟 | 构建 `bbcore` + 启动壳，新建会话确认助手与技能列表 |

验收标准：同一输入下，fork 前后的系统提示词差异只包含预期改动。

## 6. 风险

- **上游漂移**：aionrs 仍在快速迭代，提示词与 bootstrap 结构可能变化，rebase 成本随分叉面积增长；
- **编译成本**：aionrs 依赖 tokio / reqwest 等重依赖，fork 后每次改动都要重新构建；
- **Windows 工具链**：本机曾因 sysroot 缺文件导致构建失败；aionrs 上游锁定的 `memchr` 需要固定到 2.7.4；
- **事件协议耦合**：修改 turn 循环或事件格式会同时影响 `bb-conversation` 与前端渲染；
- **提示词缓存**：系统提示词在 bootstrap 时固定，运行期改动需要重建引擎。

## 7. 准备清单

- [x] 梳理现有扩展点与固定行为（本文）；
- [ ] 决定 fork 的仓库归属、分支与 tag 规则；
- [ ] 给 `buckyball` 提示词加系统提示词快照测试（fork 前建立基线）；
- [ ] 向上游提两个通用需求：提示词段落钩子、`ToolSearch` 重建；
- [ ] 明确「第一个必须 fork 的特性」，在此之前维持外部依赖；
- [ ] 更新 `just update-aionrs` 的流程说明，区分「升级上游」与「同步 fork」。

## 8. 相关文档

- 当日开发总结：[2026-10-30-dev-summary.md](2026-10-30-dev-summary.md)
- aionrs 自身文档：`docs/core-concepts.md`、`docs/tools.md`、`docs/skills.md`（fork 仓库内）
