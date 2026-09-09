# Changelog

## 0.2.0

Karmashala's coding-agent layer folded in; this package becomes its home.

- **Five modes over one descriptor table**: `launch`, `stream`, `ask`, `read`,
  `usage`, plus `discovery` and `process`.
- `AgentDescriptor` + `built_in_agents` replace `CliAgentKind`: Claude Code,
  Codex, Antigravity and Gemini CLI, each carrying the evidence its claims were
  read off. Gemini CLI is the fourth and declares only what 0.1.0 knew.
- `stream`: protocol adapters for Claude Code, Codex and Antigravity over
  `StreamingAgentSession`, plus the generic one for a registry-only agent.
- `read`: the CLIs' own stores and transcripts — Claude Code's JSONL, Codex's
  rollouts and `app-server` threads, Antigravity's conversation directory —
  located by `CliStoreLocator`.
- `usage`: token and rate-limit accounting, the signed-in account per CLI, and
  the refresh throttle.
- `ask` is 0.1.0's one-shot, kept, now built over the descriptor table.
- `CommandRunner` gains an `EnvironmentPath` working directory, `stdinText`,
  `runInShell`, `stdoutBytes` and `interrupt()`; `LocalCommandRunner` and
  `WslCommandRunner` create their processes on a worker isolate.
  `closeStdin()` is 0.1.0's and is kept.
- Adapters and `CliStoreLocator` take a `RunnerResolver`
  (`CommandRunner Function(String environmentId)`) and plain values; SQLite
  stores are read through an injected `SqliteRowReader`. The package depends on
  pub.dev only.

## 0.1.0

First release.

- `discoverEnvironments()` — this machine, plus each installed WSL distribution.
- `discoverCliAgents()` — locates Claude Code, Codex and Gemini CLI in every
  environment, with versions.
- `CliSession` — asks one question and streams the answer back.
- `CommandRunner` — the process abstraction, with native and WSL
  implementations.
