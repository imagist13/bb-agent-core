# bb-agent-core

**bb-agent-core** —— 面向 [Buckyball](https://github.com/DangoSys/buckyball)（DSA 硬件框架）的 AI 工作台本地 runtime（Rust），提供 agent loop、MCP、技能与助手，编译产物为 `bbcore` 二进制。

> 二次开发自 [AionCore](https://github.com/iOfficeAI/AionCore)（Apache-2.0），配套壳为 `bb-studio`（二次开发自 [AionUi](https://github.com/iOfficeAI/AionUi)）。

## 是什么

bb-agent-core 是工作台的本地后端。壳 `bb-studio` 启动时 spawn `bbcore` 子进程，经 REST + WebSocket 通信。
它负责 agent 执行循环、MCP 工具、技能/助手的注入，以及本地 SQLite 存储。

## 架构

26 个内部 crate 的 Rust workspace，四层依赖单向：`Composition → Domain → Capability → Foundation`。

```text
┌───────────────────────────────┐
│  bb-studio (Electron, TS)      │  chat UI · 工具渲染 · EDA 面板 · ACP host
└──────────────┬────────────────┘
               │ REST + WebSocket（spawn bbcore 子进程）
┌──────────────▼────────────────┐
│  bb-agent-core (bbcore, Rust)  │  agent loop · MCP · skills · assistants
└──────────────┬────────────────┘
               │ 子进程
        ┌──────▼───────┐
        │  bbdev (CLI)  │  verilator / bebop-verilator 仿真
        └──────────────┘
```

## 已具备的 bb 能力

- **Buckyball 助手**：`buckyball` assistant（中/英规则），默认启用。
- **17 个 bb 技能**：`ball-align` · `check` · `chip-designer` · `ip-designer` · `model-port` ·
  `model-optimize` · `debug-compiler` · `debug-bemu` · `debug-verilator` · `debug-p2e` ·
  `debug-performance` · `waveform` · `workload-tests` · `domain-modeling` · `graph-contract` ·
  `programming-principles` · `repo-install`（移植自 `.agents/skills`）。
- **MCP**：`bbdev` + `waveform`（移植自 `.agents/mcps`，运行时经 `bbcore config mcp servers` 注册）。
- **agent 引擎**：内置引擎来自外部依赖 [`aionrs`](https://github.com/iOfficeAI/aionrs)（保留为依赖），
  UI 中显示为 `bbdev`；外部 CLI agent（Claude Code / Codex 等）经 ACP 接入。

## 构建

```bash
cargo build --release -p bb-app     # 产物 target/release/bbcore(.exe)
```

> Windows 已知问题：上游锁定的 memchr 2.8.0 在 MSVC 下 AVX2 编译失败，
> `cargo update -p memchr --precise 2.7.4` 可修复。

## 现状

本地开发中，与壳 `bb-studio` 同步推进（详见 Buckyball 仓库的 `bb-agent-module-plan.md`）：

- ✅ Phase 0：骨架跑通。
- ✅ Phase 1 知识半边：助手 + 17 技能。
- ⏸ Phase 1 执行半边：bbdev 仿真闭环，待工具链（Nix / WSL）就位。

## License

[Apache-2.0](LICENSE)（沿用上游）。基于 [iOfficeAI/AionCore](https://github.com/iOfficeAI/AionCore) 二次开发。
