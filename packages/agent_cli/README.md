# agent_cli

Find and drive the AI coding CLIs already installed on a machine — **Claude
Code**, **Codex**, **Antigravity** — on the host and inside its WSL
distributions.

**Five modes over one descriptor table.** The table (`descriptors.dart`) is one
`AgentDescriptor` per CLI, and it is data: which binaries to look for, how a
prompt and a model are passed, what resume looks like, where the store is, what
each permission mode is called and what evidence that was read off. Adding an
agent is adding a descriptor.

| library | what it does |
| --- | --- |
| `launch.dart` | the argv for an interactive session in a terminal pane |
| `stream.dart` | a conversation over the CLI's own stream protocol |
| `ask.dart` | one question, one answer, tools off |
| `read.dart` | the conversations the CLIs already wrote, read off disk |
| `usage.dart` | tokens, rate limits, and which account is signed in |

Plus `discovery.dart` (which environments exist, and what is installed in each)
and `process.dart` (the runners everything above executes through).

```dart
// Which environments there are, and what is installed in each.
final environments = await EnvironmentDiscoveryService(
  host: const LocalCommandRunner(),
  clock: const SystemClock(),
).discover();
final resolve = runnerResolverFor(environments);

final installations = [
  for (final environment in environments)
    ...await AgentDiscoveryService(
      runner: resolve(environment.id),
      environment: environment,
      ids: RandomIdGenerator(),
      clock: const SystemClock(),
    ).discover(),
];

// ask: one question, one answer, tools off.
final session = CliSession(
  installation: installations.first,
  runner: resolve(installations.first.environmentId),
);
await for (final text in session.ask('What is the capital of Nepal?')) {
  stdout.write(text);
}

// read: the conversations that already exist, without running anything.
final stores = await CliStoreLocator(
  runnerFor: resolve,
  installations: installations,
).locate(environments);
final claude = AgentRegistry.builtIn.adapterFor(AgentIds.claudeCode)!;
final found = await claude.store!.sessionReader().read(
  stores.first.homeFor(claude.id)!,
  stores.first.environmentId,
);
```

## Where this came from

0.1.0 was written standalone. 0.2.0 is the coding-agent layer of
[Karmashala](https://github.com/lohanidamodar/karmashala) folded in — the
adapters, the descriptor table, the store and transcript readers, the usage and
auth services, and the process layer underneath them — with 0.1.0's one-shot
`ask` kept as the mode that layer did not have. Where the two overlapped,
Karmashala's implementation won.

**It depends on pub.dev and nothing else.** No Flutter, no Riverpod, no SQLite
binding, nothing from the application that hosts it — which is what lets its
suites run under plain `dart test` in about two seconds. The two stores that
*are* SQLite (Antigravity's conversations, Codex's thread index) are read
through an injected `SqliteRowReader`, so the binding is the caller's choice.

An application that reaches other machines — over SSH, say — adds that by
overriding one method on `CommandRunnerFactory`; the local and WSL cases are
not re-decided.

## Why this is not a one-liner

Three things decide whether it works at all, and all three were found by it not
working.

**Lookups have to go through a login shell.** These CLIs install into
`~/.local/bin`, which `~/.profile` puts on `PATH`. A non-login shell never
sources it, so a bare `which` reports nothing on a machine with two CLIs
installed. Worse, `command -v` is a shell *builtin* — there is no executable —
so `Process.run('command', ...)` fails outright. This applies on Linux and
macOS exactly as much as inside WSL.

**Tools have to be turned off and the system prompt replaced.** These are
coding agents. Left with their own prompt they will read files and run commands
instead of answering the question. Anything embedding one as a chat backend
wants an answer, not an agent loose in the working directory.

**stdin has to be closed immediately.** A CLI that reads stdin when it is not a
terminal waits forever for input that never comes — `codex exec` prints
"Reading additional input from stdin…" and then hangs.

## Environments

`discoverEnvironments()` returns a `CommandRunner` for this machine and, on
Windows, one per installed WSL distribution. That second part matters: WSL is
where these CLIs usually live on a Windows box, so a Windows app that looked
only at its own `PATH` would report nothing installed while the user has been
using `claude` all week.

Parsing `wsl --list --quiet` has its own trap — the output is UTF-16, so read
as UTF-8 every character is followed by a zero byte. Reject those lines and
every distribution name comes back empty.

## What it costs

Measured against a local llama.cpp server answering the same question:

| backend | first text |
|---|---|
| llama.cpp, Qwen3-1.7B | 95 ms |
| llama.cpp, Gemma 3 4B | 257 ms |
| Claude Code CLI | 5542 ms |
| Codex CLI | 7407 ms |

Every call is a fresh process that loads the tool list, hooks and project
instructions before it answers — one measured invocation created 8011 cache
tokens to produce five tokens of reply. This is the convenient backend, not the
fast one. If you are building something interactive, say so where the choice is
made.

## Adding a CLI

One folder, `src/agents/<agent>/`: a descriptor, and an `AgentAdapter` that
returns it and overrides the capabilities that have been established (a chat
protocol, a store, a usage endpoint, …). A `DataOnlyAgentAdapter` — a
descriptor and no code — is discovered, listed, launchable and askable, and
degrades everywhere else.

Every claim in a descriptor carries the evidence it was read off, and an
unknown is declared as unknown rather than guessed: an agent whose permission
modes nobody has read declares none, and the tests assert over the agents that
*declare* rather than over all of them.

## Statelessness (of `ask`)

Each `ask()` is a separate process, so a conversation travels in the prompt.
The CLIs do have resume modes, and `ask` deliberately does not use them: that
would move the conversation's memory into the CLI's own session store, where
the calling code cannot trim it, inspect it, or keep it consistent with the
history it believes it has. When a conversation *is* what you want, use
`stream.dart`, which is built for exactly that.

## Status

Claude Code, Codex and Antigravity are verified end to end — their descriptors
name the binary version each claim was read off. **Gemini CLI was removed in
0.2.0**: Google retired it on 2026-06-18 for individual accounts in favour of
Antigravity CLI, which this package already drives
([announcement](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/)).

## Licence

MIT.
