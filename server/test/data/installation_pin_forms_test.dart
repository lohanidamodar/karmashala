import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// **A path pinned for one form of an agent is the other form's too**, when
/// the two forms are one program: Codex in a terminal and Codex as a chat
/// both run the `codex` a person pinned on that machine, and a pin that stops
/// working sends both back to discovery.
void main() {
  late AppDatabase db;
  late DataSession app;
  late List<DataChanges> told;
  final now = DateTime.utc(2026, 10, 4, 12);
  var ids = 0;

  /// Codex's chat form on Codex's own binary, as `codex app-server` is.
  const chat = AgentDescriptor(
    id: 'codex-chat',
    displayName: 'Codex chat',
    binaries: AgentBinaries(windows: ['codex'], posix: ['codex']),
    acp: AcpLaunchSpec(),
    chatFormOf: AgentIds.codex,
  );
  final registry = AgentRegistry([
    builtInAgentAdapters.firstWhere((a) => a.id == AgentIds.codex),
    const DataOnlyAgentAdapter(chat),
    for (final a in builtInAgentAdapters)
      if (a.id == AgentIds.antigravity || a.id == AgentIds.antigravityAcp) a,
  ]);

  late DataService service;

  setUp(() {
    db = AppDatabase.memory();
    ids = 0;
    service = DataService(
      db,
      clock: () => now,
      newId: () => 'new-${ids++}',
      agents: registry,
    );
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
    for (final id in ['windows', 'wsl:Ubuntu']) {
      app.handle(
        EnvironmentPut(
          ExecutionEnvironment(
            id: id,
            kind: id == 'windows'
                ? EnvironmentKind.windowsNative
                : EnvironmentKind.wsl,
            name: id,
            wslDistribution: id == 'windows' ? null : 'Ubuntu',
            createdAt: now,
          ),
        ),
      );
    }
  });
  tearDown(() => db.close());

  AgentInstallation found(
    String id,
    String agentId,
    String path, {
    String environmentId = 'windows',
  }) => AgentInstallation(
    id: id,
    agentId: agentId,
    executable: EnvironmentPath(environmentId: environmentId, path: path),
    createdAt: now,
  );

  void sweep(
    List<AgentInstallation> rows, {
    String environmentId = 'windows',
    Map<String, ExecutableReachability> readings = const {},
  }) => service.reconcileProbe(
    environmentId: environmentId,
    readAt: now,
    found: rows,
    probed: {for (final r in rows) r.agentId},
    readings: readings,
  );

  List<AgentInstallation> rows() =>
      app.handle(const AgentsList()).value.installations;
  AgentInstallation row(String id) => rows().firstWhere((r) => r.id == id);

  test('pinning the terminal form pins the chat form on that machine to the '
      'same binary, and tells', () {
    sweep([
      found('t', AgentIds.codex, r'C:\npm\codex.cmd'),
      found('c', 'codex-chat', r'C:\npm\codex.cmd'),
    ]);
    sweep([
      found('wt', AgentIds.codex, '/usr/bin/codex', environmentId: 'wsl:Ubuntu'),
      found('wc', 'codex-chat', '/usr/bin/codex', environmentId: 'wsl:Ubuntu'),
    ], environmentId: 'wsl:Ubuntu');
    told.clear();

    app.handle(const InstallationSetPath(id: 't', path: r'C:\tools\codex.exe'));

    expect(row('c').executable.path, r'C:\tools\codex.exe');
    expect(row('c').executableByUser, isTrue);
    expect(
      [
        for (final b in told)
          for (final c in b.changes.whereType<InstallationChanged>())
            c.installation.id,
      ],
      containsAll(['t', 'c']),
    );
    // Another machine's chat form keeps its own.
    expect(row('wc').executable.path, '/usr/bin/codex');
    expect(row('wc').executableByUser, isFalse);
  });

  test('a chat form discovery never found there is recorded at the pin', () {
    sweep([found('t', AgentIds.codex, r'C:\npm\codex.cmd')]);
    app.handle(const InstallationSetPath(id: 't', path: r'C:\tools\codex.exe'));

    final chatRow = rows().singleWhere((r) => r.agentId == 'codex-chat');
    expect(chatRow.environmentId, 'windows');
    expect(chatRow.executable.path, r'C:\tools\codex.exe');
    expect(chatRow.executableByUser, isTrue);
  });

  test('a pin that stops working sends both forms back to discovery', () {
    sweep([
      found('t', AgentIds.codex, r'C:\npm\codex.cmd'),
      found('c', 'codex-chat', r'C:\npm\codex.cmd'),
    ]);
    app.handle(const InstallationSetPath(id: 't', path: r'C:\tools\codex.exe'));

    sweep(
      [
        found('t2', AgentIds.codex, r'C:\npm\codex.cmd'),
        found('c2', 'codex-chat', r'C:\npm\codex.cmd'),
      ],
      readings: {
        't': ExecutableReachability.missing,
        'c': ExecutableReachability.missing,
      },
    );
    for (final id in ['t', 'c']) {
      expect(row(id).executable.path, r'C:\npm\codex.cmd');
      expect(row(id).executableByUser, isFalse);
    }
  });

  test('a chat form that is a program of its own does not follow', () {
    sweep([
      found('a', AgentIds.antigravity, r'C:\agy\agy.exe'),
      found('ac', AgentIds.antigravityAcp, r'C:\agy\agy_acp_server.exe'),
    ]);
    app.handle(const InstallationSetPath(id: 'a', path: r'C:\pin\agy.exe'));
    expect(row('ac').executable.path, r'C:\agy\agy_acp_server.exe');
    expect(row('ac').executableByUser, isFalse);
  });
}
