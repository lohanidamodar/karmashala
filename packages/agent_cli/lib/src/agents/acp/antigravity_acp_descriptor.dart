import '../domain/agent_descriptor.dart';

/// Google Antigravity's ACP server (`agy_acp_server`), spoken to over ACP.
///
/// Published by the public ACP registry as `antigravity-acp` — a prebuilt
/// archive per platform, not an npm package, and no `--acp` flag on the `agy`
/// CLI — so it is found on PATH or in the folder Karmashala installs it to.
/// Its version is read over ACP (`agentInfo.version`): `--version` prints a
/// build stamp, not a version. The registry passes `--uid=` on Linux, a no-op
/// unless run as root. No modes are declared, so the picker offers nothing
/// rather than a guess.
const antigravityAcpDescriptor = AgentDescriptor(
  id: 'antigravity-acp',
  displayName: 'Antigravity (ACP)',
  binaries: AgentBinaries(
    windows: ['agy_acp_server.exe'],
    posix: ['agy_acp_server.par', 'agy_acp_server'],
  ),
  discovery: AgentDiscoveryRules(probeVersion: false),
  store: AgentStoreSpec(homeDirectoryName: '.gemini/antigravity-acp'),
  // Its `gemini-api-key` method reads the key the Gemini tools document.
  acp: AcpLaunchSpec(
    linuxArguments: ['--uid='],
    registryId: 'antigravity-acp',
    apiKeyVariables: {'gemini-api-key': 'GEMINI_API_KEY'},
  ),
);
