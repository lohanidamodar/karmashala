import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:karmashala_environments/sweep.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/agents/server_agent_work.dart';
import 'package:karmashala_host/src/agents/server_detection.dart';
import 'package:karmashala_host/src/data/agent_work.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'agent_work_support.dart';

/// **Finding the agent CLIs, by the server** (slice 2a): the wiring, not the
/// sweep's rules (those are `karmashala_environments`' own tests) — a
/// client's `agents.detect` / `agents.repair` / `agents.discoverUnprobed`
/// writes rows by the one reconciliation and tells every other client; the
/// probe log is the server's own record under a reserved key, never a
/// preference; an SSH box's commands go through the app. Every command is
/// answered by a script; nothing is spawned.
void main() {
  final now = DateTime.utc(2026, 9, 26, 12);
  const newPath = r'C:\bin\claude.exe';
  const oldPath = r'C:\old\claude.exe';

  late MutableClock clock;
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  late ScriptedRunner runner;
  late SetPathProbe disk;
  late ServerDetection detection;

  ExecutionEnvironment windows() => ExecutionEnvironment(
    id: 'windows',
    kind: EnvironmentKind.windowsNative,
    name: 'Windows',
    createdAt: now,
  );

  // Only Claude Code is installed, on the PATH.
  CommandResult claudeOnly(CommandRequest request) {
    if (request.executable == 'where') {
      return request.arguments.first == 'claude'
          ? const CommandResult(exitCode: 0, stdout: '$newPath\n', stderr: '')
          : notFound;
    }
    if (request.executable == newPath) {
      return const CommandResult(
        exitCode: 0,
        stdout: '2.1.0 (Claude Code)\n',
        stderr: '',
      );
    }
    return notFound;
  }

  List<DataChange> toldChanges() => [for (final b in told) ...b.changes];

  List<AgentInstallation> rows() =>
      app.handle(const AgentsList()).value.installations;

  setUp(() {
    clock = MutableClock(now);
    db = AppDatabase.memory();
    service = DataService(db, clock: () => clock.now);
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
    service.ensureEnvironment(windows());
    runner = ScriptedRunner(claudeOnly);
    disk = SetPathProbe({newPath});
    detection = ServerDetection(
      data: service,
      runnerFor: (_) => runner,
      ids: CountingIds('found'),
      clock: clock,
      pathProbe: disk,
    );
    service.agentWork = _DetectionWork(detection);
    told.clear();
  });

  tearDown(() => db.close());

  group('agents.detect', () {
    test(
      'probes an agent added while the server runs, on the next detect',
      () async {
        // The registry as the holder would hand it: built-ins first, then a
        // row a person added from Settings.
        var registry = AgentRegistry.builtIn;
        const copilotPath = r'C:\bin\copilot.exe';
        runner = ScriptedRunner((request) {
          if (request.executable == 'where' &&
              request.arguments.first == 'copilot') {
            return const CommandResult(
              exitCode: 0,
              stdout: '$copilotPath\n',
              stderr: '',
            );
          }
          return claudeOnly(request);
        });
        disk = SetPathProbe({newPath, copilotPath});
        detection = ServerDetection(
          data: service,
          runnerFor: (_) => runner,
          ids: CountingIds('found'),
          clock: clock,
          pathProbe: disk,
          registryNow: () => registry,
        );
        service.agentWork = _DetectionWork(detection);

        final before = (await app.handleLater(const AgentsDetect())).value;
        expect(
          before.environments.single.added.single.agentId,
          AgentIds.claudeCode,
        );

        final row = AcpAgentRow(
          id: 'row-1',
          name: 'GitHub Copilot',
          command: 'copilot',
          args: const ['--acp'],
          env: const {},
          source: AcpAgentSource.custom,
          createdAt: now,
        );
        registry = AgentRegistry.withExtra([acpAgentAdapter(row)]);

        final after = (await app.handleLater(const AgentsDetect())).value;
        expect(
          after.environments.single.added.map((i) => i.agentId),
          [row.agentId],
          reason:
              'the sweep read the registry again rather than the one it began with',
        );
        expect(
          rows().map((i) => i.agentId),
          containsAll([AgentIds.claudeCode, row.agentId]),
        );
      },
    );

    test('writes what answered, tells every other client, and logs the '
        'search under the server\'s own key', () async {
      final report = (await app.handleLater(const AgentsDetect())).value;
      final scan = report.environments.single;
      expect(scan.reachable, isTrue);
      expect(scan.added.single.agentId, AgentIds.claudeCode);
      expect(scan.added.single.executable.path, newPath);
      expect(scan.added.single.version, '2.1.0');
      // Every built-in but the one found, the ACP agents included.
      expect(scan.missing, [
        for (final id in AgentIds.builtIn)
          if (id != AgentIds.claudeCode)
            AgentRegistry.builtIn.displayNameFor(id),
      ]);

      expect(rows().single.agentId, AgentIds.claudeCode);
      expect(
        toldChanges().whereType<InstallationChanged>().single.installation.id,
        rows().single.id,
      );

      final log = AgentProbeLog(
        read: () => service.serverValue(AgentProbeLog.key),
        write: (_) => fail('only read here'),
      );
      expect(AgentProbeLog.key, 'agents_probed');
      for (final agentId in AgentIds.builtIn) {
        expect(log.hasProbed(agentId, 'windows'), isTrue, reason: agentId);
      }
    });

    test('the probe log is not a client preference', () async {
      await app.handleLater(const AgentsDetect());
      expect(service.serverValue(AgentProbeLog.key), isNotNull);
      final preferences = app.handle(const PreferencesGet()).value;
      expect(preferences.containsKey(AgentProbeLog.key), isFalse);
      expect(
        () => app.handle(const PreferenceSet(AgentProbeLog.key, '{}')),
        throwsA(
          isA<DataRefused>().having(
            (r) => r.code,
            'code',
            DataRefusalCode.reserved,
          ),
        ),
      );
      expect(
        service.serverValue(AgentProbeLog.key),
        isNot('{}'),
        reason: 'a refused write wrote nothing',
      );
    });

    test('a second detect finds the same row, not a second one', () async {
      await app.handleLater(const AgentsDetect());
      final first = rows().single.id;
      await app.handleLater(const AgentsDetect());
      expect(rows().single.id, first);
    });

    test(
      'one environment\'s scan only adds; an unknown one is notFound',
      () async {
        service.reconcileProbe(
          environmentId: 'windows',
          readAt: now,
          found: [
            AgentInstallation(
              id: 'codex-kept',
              agentId: AgentIds.codex,
              executable: const EnvironmentPath(
                environmentId: 'windows',
                path: r'C:\bin\codex.exe',
              ),
              createdAt: now,
            ),
          ],
          probed: const {},
          readings: const {},
        );
        final report = (await app.handleLater(
          const AgentsDetect(environmentId: 'windows'),
        )).value;
        expect(report.environments.single.added.single.agentId, 'claudeCode');
        expect(
          rows().map((r) => r.id),
          contains('codex-kept'),
          reason: 'a scan judges nothing it did not find',
        );

        final answer = await app.handleJson({
          'id': 4,
          'kind': AgentsDetect.name,
          'arguments': {'environmentId': 'wsl:Nope'},
        });
        expect(
          (answer['refusal'] as Map)['code'],
          DataRefusalCode.notFound.name,
        );
      },
    );
  });

  group('agents.repair', () {
    test('a rotted path is found again and the row keeps its id', () async {
      service.reconcileProbe(
        environmentId: 'windows',
        readAt: now,
        found: [
          AgentInstallation(
            id: 'mine',
            agentId: AgentIds.claudeCode,
            executable: const EnvironmentPath(
              environmentId: 'windows',
              path: oldPath,
            ),
            createdAt: now,
          ),
        ],
        probed: const {},
        readings: const {},
      );
      told.clear();

      final report = (await app.handleLater(const AgentsRepair())).value;
      expect(report.broken.single.installation.id, 'mine');
      expect(report.repaired.single.installation.id, 'mine');
      expect(report.repaired.single.reading.path, newPath);
      expect(rows().single.id, 'mine');
      expect(rows().single.executable.path, newPath);
      expect(
        toldChanges()
            .whereType<InstallationChanged>()
            .last
            .installation
            .executable
            .path,
        newPath,
      );
    });

    test('nothing broken asks nothing — unless it is full', () async {
      final quiet = (await app.handleLater(const AgentsRepair())).value;
      expect(quiet.checkedAt, now);
      expect(quiet.broken, isEmpty);
      expect(runner.requests, isEmpty);

      final full = (await app.handleLater(
        const AgentsRepair(full: true),
      )).value;
      expect(full.scan, isNotNull);
      expect(runner.requests, isNotEmpty);
      expect(rows().single.agentId, AgentIds.claudeCode);
    });
  });

  group('agents.discoverUnprobed', () {
    test('searches only what nobody searched, once', () async {
      final found = (await app.handleLater(
        const AgentsDiscoverUnprobed(),
      )).value;
      expect(found.single.agentId, AgentIds.claudeCode);
      expect(rows().single.executable.path, newPath);
      expect(toldChanges().whereType<InstallationChanged>(), hasLength(1));

      runner.requests.clear();
      final again = (await app.handleLater(
        const AgentsDiscoverUnprobed(),
      )).value;
      expect(again, isEmpty);
      expect(runner.requests, isEmpty, reason: 'every pair is in the log');
    });

    test('agents.refreshVersions re-reads an aged version', () async {
      await app.handleLater(const AgentsDetect());
      clock.advance(const Duration(days: 30));
      runner.responder = (request) => request.executable == newPath
          ? const CommandResult(exitCode: 0, stdout: '2.2.0\n', stderr: '')
          : notFound;
      final changes = (await app.handleLater(
        const AgentsRefreshVersions(),
      )).value;
      expect(changes.single.to, '2.2.0');
      expect(rows().single.version, '2.2.0');
    });
  });

  group('an SSH box, over the server\'s own connection', () {
    late ServerAgentWork work;
    late ScriptedRunner box;

    setUp(() {
      app.handle(
        SshHostPut(
          SshHost(
            id: 'h1',
            name: 'build-box',
            host: 'build.example.com',
            port: 22,
            username: 'dev',
            authMethod: SshAuthMethod.password,
            createdAt: now,
          ),
        ),
      );
      box = ScriptedRunner((request) {
        final script = request.arguments.join(' ');
        if (script.contains('exit 0')) {
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        }
        // The word itself, not a prefix: `claude-agent-acp` is probed too.
        if (RegExp(r'command -v claude(\s|$)').hasMatch(script)) {
          return const CommandResult(
            exitCode: 0,
            stdout: '/home/dev/.local/bin/claude\n',
            stderr: '',
          );
        }
        if (request.executable == '/home/dev/.local/bin/claude') {
          return const CommandResult(
            exitCode: 0,
            stdout: '2.1.0\n',
            stderr: '',
          );
        }
        return const CommandResult(exitCode: 1, stdout: '', stderr: '');
      }, environmentId: sshEnvironmentId('h1'));
      work = ServerAgentWork(
        data: service,
        runners: _BoxRunners(box),
        clock: clock,
        ids: CountingIds('ssh'),
        usageService: (_) => ScriptedUsageService(
          clock: clock,
          answer: (_) => throw UsageException('not in this test'),
        ),
        claudeAuth: ClaudeAuthService(
          ids: CountingIds('claude'),
          clock: clock,
          readKeychain: () async => const ClaudeKeychainRead.notFound(),
        ),
        onItsOwn: false,
      )..attach();
      told.clear();
    });

    tearDown(() => work.stop());

    test(
      'each command runs on the box, and what answered is recorded',
      () async {
        final report = (await app.handleLater(
          AgentsDetect(environmentId: sshEnvironmentId('h1')),
        )).value;
        final scan = report.environments.single;
        expect(scan.reachable, isTrue, reason: scan.error);
        expect(
          scan.added.single.executable.path,
          '/home/dev/.local/bin/claude',
        );
        expect(scan.added.single.version, '2.1.0');
        expect(box.requests, isNotEmpty);
        expect(
          rows().where((r) => r.environmentId == sshEnvironmentId('h1')),
          hasLength(1),
        );
        expect(toldChanges().whereType<InstallationChanged>(), hasLength(1));
      },
    );

    test('a box that cannot be reached is unreachable, in its words', () async {
      box.responder = (_) => throw CommandException(
        'build.example.com needs a password, and no Karmashala window is '
        'connected to ask for it.',
      );
      final report = (await app.handleLater(
        AgentsDetect(environmentId: sshEnvironmentId('h1')),
      )).value;
      expect(report.environments.single.reachable, isFalse);
      expect(
        report.environments.single.error,
        contains('no Karmashala window is connected'),
      );
    });
  });
}

/// The server's runners with [box] standing in for the SSH connection.
class _BoxRunners extends CommandRunnerFactory {
  const _BoxRunners(this.box);

  final CommandRunner box;

  @override
  bool get canReachRemote => true;

  @override
  CommandRunner unsupported(ExecutionEnvironment environment) => box;
}

/// The detection half of `ServerAgentWork.handle`, over a [ServerDetection]
/// whose commands are scripted.
class _DetectionWork implements AgentWork {
  _DetectionWork(this.detection);

  final ServerDetection detection;

  @override
  Future<Object?> handle(AgentWorkRequest<Object?> request) async =>
      switch (request) {
        AgentsDetect(:final environmentId) => await detection.detect(
          environmentId: environmentId,
        ),
        AgentsRepair(:final full) => await detection.repair(full: full),
        AgentsRefreshVersions() => await detection.refreshVersions(),
        AgentsDiscoverUnprobed() => await detection.discoverUnprobed(),
        _ => throw DataRefused.invalid('${request.kind} is not detection'),
      };

  @override
  List<AccountUsageState> usageStates() => const [];
}
