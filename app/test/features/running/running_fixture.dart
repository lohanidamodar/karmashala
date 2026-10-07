import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// A realistic reading: the server with its four ports; "analytics", an agent
/// session in WSL whose vite holds 3000; "new features", an agent session on
/// Windows running six flutter_testers among console noise; "deploy api" on
/// an SSH box; postgres in WSL that no session started; adb mirroring.
final RunningReading runningFixture = RunningReading(
  serverPid: 38080,
  checkedAt: DateTime.utc(2026, 10, 7, 7, 36, 18),
  processes: [
    const RunningProcess(
      pid: 38080,
      parent: 1,
      name: 'karmashala_host.exe',
      role: RunningRole.server,
      ports: [
        RunningPort(port: 8787, address: '127.0.0.1', label: 'Local relay'),
        RunningPort(
          port: 47820,
          address: '0.0.0.0',
          label: 'Paired devices (LAN)',
        ),
        RunningPort(port: 47821, address: '127.0.0.1', label: 'MCP endpoint'),
        RunningPort(port: 53491, address: '127.0.0.1', label: 'Server'),
      ],
    ),
    // analytics: the Windows side of a WSL pane is all relays.
    ..._windowsSide('pa', 'analytics', 'sa', 'wsl:archlinux', 42376, [
      (40472, 'wsl.exe'),
      (5256, 'cmd.exe'),
      (47300, 'conhost.exe'),
      (13964, 'conhost.exe'),
      (46336, 'wslhost.exe'),
    ]),
    for (final (pid, parent, name, line, ports) in [
      (410, 401, 'bash', '/bin/bash -l', <RunningPort>[]),
      (411, 410, 'node', 'node /home/dev/.local/bin/claude', <RunningPort>[]),
      (420, 411, 'npm run dev', 'npm run dev', <RunningPort>[]),
      (
        421,
        420,
        'node',
        'node /work/site/node_modules/.bin/vite --port 3000',
        [const RunningPort(port: 3000, address: '0.0.0.0')],
      ),
      (422, 421, 'esbuild', 'esbuild --service=0.25.0', <RunningPort>[]),
    ])
      RunningProcess(
        pid: pid,
        parent: parent,
        name: name,
        role: RunningRole.child,
        paneId: 'pa',
        terminalSessionId: 'karmashala_sa',
        title: 'analytics',
        agentSessionId: 'sa',
        environmentId: 'wsl:archlinux',
        pidMachine: 'wsl:archlinux',
        commandLine: line,
        stoppable: pid != 410,
        ports: ports,
      ),
    const RunningProcess(
      pid: 500,
      parent: 1,
      name: 'postgres',
      role: RunningRole.listener,
      environmentId: 'wsl:archlinux',
      pidMachine: 'wsl:archlinux',
      commandLine: 'postgres -D /var/lib/postgres/data',
      ports: [RunningPort(port: 5432, address: '127.0.0.1')],
    ),
    // new features: an agent on Windows running a test suite.
    ..._windowsSide(
      'pn',
      'new features',
      'sn',
      null,
      31184,
      [
        (43372, 'claude.exe'),
        (37020, 'cmd.exe'),
        (47236, 'dart.exe'),
        (20512, 'dartvm.exe'),
        for (final pid in [48492, 8096, 5808, 37064, 38860, 46284])
          (pid, 'flutter_tester.exe'),
        for (final pid in [21704, 35836, 38624, 41036, 39676, 41216])
          (pid, 'conhost.exe'),
        (42192, 'dartaotruntime.exe'),
      ],
      vmPorts: {
        20512: [55134, 56564],
      },
    ),
    // deploy api: an agent on an SSH box, its server on 8080.
    const RunningProcess(
      pid: 0,
      parent: 0,
      role: RunningRole.pane,
      paneId: 'pd',
      terminalSessionId: 'ssh:box/karmashala_sd',
      title: 'deploy api',
      agentSessionId: 'sd',
      environmentId: 'ssh:box',
    ),
    const RunningProcess(
      pid: 7712,
      parent: 7700,
      name: 'node',
      role: RunningRole.child,
      paneId: 'pd',
      terminalSessionId: 'ssh:box/karmashala_sd',
      title: 'deploy api',
      agentSessionId: 'sd',
      environmentId: 'ssh:box',
      pidMachine: 'ssh:box',
      commandLine: 'node dist/server.js',
      stoppable: true,
      ports: [RunningPort(port: 8080, address: '0.0.0.0', host: 'box.example')],
    ),
    const RunningProcess(
      pid: 18508,
      parent: 1,
      name: 'adb.exe',
      role: RunningRole.device,
      ports: [RunningPort(port: 5037, address: '127.0.0.1')],
    ),
  ],
  notes: const [
    RunningNote(
      'The adb server was restarted 2 minutes ago; forwards made before '
      'then are gone.',
    ),
  ],
);

List<RunningProcess> _windowsSide(
  String paneId,
  String title,
  String sessionId,
  String? environmentId,
  int root,
  List<(int, String)> children, {
  Map<int, List<int>> vmPorts = const {},
}) => [
  RunningProcess(
    pid: root,
    parent: 1,
    name: environmentId == null ? 'powershell.exe' : 'wsl.exe',
    role: RunningRole.pane,
    paneId: paneId,
    terminalSessionId: 'karmashala_$sessionId',
    title: title,
    agentSessionId: sessionId,
    environmentId: environmentId,
  ),
  for (final (pid, name) in children)
    RunningProcess(
      pid: pid,
      parent: root,
      name: name,
      role: RunningRole.child,
      paneId: paneId,
      terminalSessionId: 'karmashala_$sessionId',
      title: title,
      agentSessionId: sessionId,
      environmentId: environmentId,
      stoppable: true,
      ports: [
        for (final port in vmPorts[pid] ?? const <int>[])
          RunningPort(port: port, address: '127.0.0.1'),
      ],
    ),
];

final fixtureLocal = ExecutionEnvironment(
  id: 'windows',
  createdAt: DateTime.utc(2026),
  name: 'Windows',
  kind: EnvironmentKind.windowsNative,
);

final fixtureWsl = ExecutionEnvironment(
  id: 'wsl:archlinux',
  createdAt: DateTime.utc(2026),
  name: 'archlinux',
  kind: EnvironmentKind.wsl,
  wslDistribution: 'archlinux',
);

final fixtureBox = ExecutionEnvironment(
  id: 'ssh:box',
  createdAt: DateTime.utc(2026),
  name: 'build box',
  kind: EnvironmentKind.ssh,
  sshHostId: 'box',
);
