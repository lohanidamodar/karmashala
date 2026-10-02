import '../domain/agent_descriptor.dart';

/// Google Antigravity's ACP server (`agy_acp_server`), spoken to over ACP.
///
/// Published by the public ACP registry as `antigravity-acp` — a prebuilt
/// archive per platform, not an npm package, and no `--acp` flag on the `agy`
/// CLI — so it is found on PATH or in the folder Karmashala installs it to.
/// Measured 2026-10-02 against 1.3.0 in WSL: `initialize` answers
/// `agentInfo.version` (read over ACP, so no `--version` probe — that flag
/// prints a build stamp, not a version), and `session/new` needs one of the
/// advertised auth methods first; its settings live under
/// `~/.gemini/antigravity-acp/`. The registry passes `--uid=` on Linux: a
/// base flag that would drop privileges when root, a no-op otherwise.
///
/// Its modes have not been read off a live session — none are declared, so
/// the picker offers nothing rather than a guess.
const antigravityAcpDescriptor = AgentDescriptor(
  id: 'antigravity-acp',
  displayName: 'Antigravity (ACP)',
  binaries: AgentBinaries(
    windows: ['agy_acp_server.exe'],
    posix: ['agy_acp_server.par', 'agy_acp_server'],
  ),
  discovery: AgentDiscoveryRules(probeVersion: false),
  store: AgentStoreSpec(homeDirectoryName: '.gemini/antigravity-acp'),
  acp: AcpLaunchSpec(linuxArguments: ['--uid='], registryId: 'antigravity-acp'),
);
