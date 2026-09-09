import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/environments/application/environment_health.dart';
import 'package:karmashala/src/features/environments/application/system_health.dart';
import 'package:karmashala/src/features/environments/application/system_health_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/mcp/control_server_status.dart';
import 'package:karmashala/src/features/mcp/mcp_bridge_probe.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

/// The verdicts the health panel is allowed to state, and the evidence behind
/// each one.
///
/// The panel this replaces had two verdicts — the file is there, or it is not —
/// and on 2026-09-03 the first of them was on screen for over an hour while
/// every agent session on the machine had lost every Karmashala tool. So the
/// wording is pinned: each row must say what was observed, offer what to do
/// about it, and never imply a measurement that was not taken.
void main() {
  late AppDatabase db;
  late Directory temp;

  setUp(() {
    db = AppDatabase.memory();
    temp = Directory.systemTemp.createTempSync('system_health');
  });
  tearDown(() {
    db.close();
    removeTempDirectory(temp);
  });

  const initializeResult =
      '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05",'
      '"capabilities":{"tools":{}},'
      '"serverInfo":{"name":"karmashala","version":"1.0.0"}}}';

  /// A host runner that answers every probe the checks make with "nothing
  /// here", so a case can script only the one it cares about.
  FakeCommandRunner quietHost({
    CommandResult? Function(CommandRequest request)? responder,
  }) => FakeCommandRunner(
    responder: (request) {
      final scripted = responder?.call(request);
      if (scripted != null) return scripted;
      // Every SDK candidate probe fails: no Android SDK on this machine.
      return const CommandResult(exitCode: 1, stdout: '', stderr: '');
    },
  );

  ProviderContainer containerWith({
    required McpBridgeProbe probe,
    FakeCommandRunner? host,
    FakeCommandRunnerFactory? factory,
    ControlServerStatus control = const ControlServerStatus.running(
      PrivilegedRpcTransport.ownerOnlySocket,
    ),
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        hostCommandRunnerProvider.overrideWithValue(host ?? quietHost()),
        commandRunnerFactoryProvider.overrideWithValue(
          factory ?? FakeCommandRunnerFactory(),
        ),
        mcpBridgeProbeProvider.overrideWithValue(probe),
        systemHealthServiceProvider.overrideWith((ref) {
          return SystemHealthService(ref)
            ..supportDirectory = (() async => temp)
            ..directoryExists = ((_) => false)
            ..readTextFile = ((_) => null);
        }),
      ],
    );
    container.read(controlServerStatusProvider.notifier).set(control);
    return container;
  }

  McpBridgeProbe probeReturning(
    ProcessHandleScript script, {
    File? Function()? locate,
  }) => McpBridgeProbe(
    runner: FakeCommandRunner(
      throwError: script.startError,
      processFactory: script.startError == null
          ? (_) {
              final handle = FakeProcessHandle();
              script.drive(handle);
              return handle;
            }
          : null,
    ),
    bridgeExecutable:
        locate ?? () => File('${temp.path}/karmashala_mcp')
          ..writeAsStringSync(''),
    timeout: const Duration(milliseconds: 100),
  );

  Future<SystemCheck> bridgeCheck(ProviderContainer container) async {
    final checks = await container.read(systemHealthServiceProvider).checkAll();
    return checks.firstWhere((c) => c.id == SystemCheckId.mcpBridge);
  }

  group('the MCP bridge, in the four states that need four answers', () {
    test('answering', () async {
      final container = containerWith(
        probe: probeReturning(ProcessHandleScript.replies(initializeResult)),
      );
      addTearDown(container.dispose);

      final check = await bridgeCheck(container);

      expect(check.level, HealthLevel.healthy);
      expect(
        check.summary,
        'Answering — the bridge started and finished an MCP initialize '
        'handshake.',
      );
      // The evidence is the server's own words, not our summary of them.
      expect(check.detail, contains('server karmashala 1.0.0'));
      // A verdict that says nothing about what it cost is a verdict nobody can
      // weigh against re-running it.
      expect(check.took, isNotNull);
      expect(check.remedy, isNull);
    });

    test('present but unspawnable — 2026-09-03, three times', () async {
      final container = containerWith(
        probe: probeReturning(
          ProcessHandleScript.failsToStart(
            CommandException(
              'Failed to start "karmashala_mcp.exe" on windows',
              cause: const ProcessException(
                'karmashala_mcp.exe',
                [],
                'ENOEXEC: unknown error',
                8,
              ),
            ),
          ),
        ),
      );
      addTearDown(container.dispose);

      final check = await bridgeCheck(container);

      expect(check.level, HealthLevel.failed);
      expect(
        check.summary,
        'Present but unspawnable — the file is beside the app and this '
        'machine refused to start it.',
      );
      expect(check.detail, contains('ENOEXEC'));
      // It points at the interop row rather than absorbing its explanation:
      // this row speaks for the host's own spawn, which is a different
      // mechanism from a WSL session's.
      expect(check.remedy, contains('interop row'));
    });

    test('not present at all', () async {
      final container = containerWith(
        probe: probeReturning(
          ProcessHandleScript.replies(initializeResult),
          locate: () => null,
        ),
      );
      addTearDown(container.dispose);

      final check = await bridgeCheck(container);

      // A warning, not a failure: the HTTP endpoint still serves every session
      // that is not inside WSL.
      expect(check.level, HealthLevel.warning);
      expect(
        check.summary,
        'Not found — there is no karmashala_mcp beside the app for an agent '
        'to spawn.',
      );
      expect(check.remedy, contains('WSL switch address'));
      expect(check.remedyCommand, contains('dart compile exe'));
    });

    test('spawned, but the handshake never completed', () async {
      final container = containerWith(
        probe: probeReturning(ProcessHandleScript.silent()),
      );
      addTearDown(container.dispose);

      final check = await bridgeCheck(container);

      expect(check.level, HealthLevel.failed);
      expect(
        check.summary,
        'Spawned but not answering — the process started and the MCP '
        'initialize handshake did not complete.',
      );
      expect(check.detail, contains('No reply within'));
    });
  });

  group('the agent tools endpoint sits beside the bridge, not inside it', () {
    test('a fail-closed server is reported as the server reported it', () async {
      final container = containerWith(
        probe: probeReturning(ProcessHandleScript.replies(initializeResult)),
        control: const ControlServerStatus.failedClosed(
          stage: ControlServerFailureStage.socketBind,
          detail: 'bind failed: permission denied',
        ),
      );
      addTearDown(container.dispose);

      final checks = await container
          .read(systemHealthServiceProvider)
          .checkAll();
      final endpoint = checks.firstWhere(
        (c) => c.id == SystemCheckId.controlServer,
      );

      expect(endpoint.level, HealthLevel.failed);
      expect(endpoint.summary, contains('the owner-only socket could not be'));
      expect(endpoint.detail, contains('bind failed: permission denied'));
      // This row is read from what the server recorded, not probed — and it
      // says so, so the panel's timestamp cannot imply a fresh measurement.
      expect(endpoint.detail, contains('nothing was probed for this row'));
      expect(endpoint.took, Duration.zero);
    });

    test('a server that never started is unknown, not healthy', () async {
      final container = containerWith(
        probe: probeReturning(ProcessHandleScript.replies(initializeResult)),
        control: ControlServerStatus.notStarted,
      );
      addTearDown(container.dispose);

      final checks = await container
          .read(systemHealthServiceProvider)
          .checkAll();
      final endpoint = checks.firstWhere(
        (c) => c.id == SystemCheckId.controlServer,
      );

      expect(endpoint.level, HealthLevel.unknown);
    });
  });

  group('WSL interop is its own row, once per distribution', () {
    ProviderContainer withDistro(CommandResult Function(CommandRequest) reply) {
      ExecutionEnvironmentDao(db)
        ..upsert(windowsEnv())
        ..upsert(wslEnv(id: 'wsl:archlinux', distro: 'archlinux'));
      return containerWith(
        probe: probeReturning(ProcessHandleScript.replies(initializeResult)),
        factory: FakeCommandRunnerFactory(
          byEnvironmentId: {
            'wsl:archlinux': FakeCommandRunner(responder: reply),
          },
        ),
      );
    }

    Future<SystemCheck> interopCheck(ProviderContainer container) async {
      final checks = await container
          .read(systemHealthServiceProvider)
          .checkAll();
      return checks.firstWhere((c) => c.id == SystemCheckId.wslInterop);
    }

    test('a registered handler means Windows programs run there', () async {
      final container = withDistro(
        (_) => CommandResult(
          exitCode: 0,
          stdout:
              '${kInteropMarker}WSLInterop=enabled\n'
              '${kInteropMarker}checked=1\n',
          stderr: '',
        ),
      );
      addTearDown(container.dispose);

      final check = await interopCheck(container);

      expect(check.title, 'WSL → Windows interop (archlinux)');
      expect(check.level, HealthLevel.healthy);
      expect(check.summary, contains('Windows programs run'));
    });

    test('a missing handler names the class of failure and the fix', () async {
      final container = withDistro(
        (_) => CommandResult(
          exitCode: 0,
          stdout: '${kInteropMarker}checked=1\n',
          stderr: '',
        ),
      );
      addTearDown(container.dispose);

      final check = await interopCheck(container);

      expect(check.level, HealthLevel.failed);
      expect(check.summary, contains('fails with ENOEXEC'));
      // The whole point of this row: it explains the MCP bridge, cmd.exe and
      // every Windows build tool in one line rather than one row each.
      expect(check.remedy, contains('takes out everything at once'));
      expect(check.remedyCommand, kWslInteropRepairCommand);
    });

    test('a distribution that does not answer is unknown, not broken', () async {
      final container = withDistro((_) => throw CommandException('no wsl'));
      addTearDown(container.dispose);

      final check = await interopCheck(container);

      expect(check.level, HealthLevel.unknown);
      expect(check.summary, contains('archlinux did not answer'));
    });

    test('a machine with no WSL gets no interop row at all', () async {
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      final container = containerWith(
        probe: probeReturning(ProcessHandleScript.replies(initializeResult)),
      );
      addTearDown(container.dispose);

      final checks = await container
          .read(systemHealthServiceProvider)
          .checkAll();

      expect(checks.where((c) => c.id == SystemCheckId.wslInterop), isEmpty);
    });
  });

  group('disk space', () {
    Future<SystemCheck> diskCheck(String stdout) async {
      final container = containerWith(
        probe: probeReturning(ProcessHandleScript.replies(initializeResult)),
        host: quietHost(
          responder: (request) =>
              request.executable == 'powershell' || request.executable == 'df'
              ? CommandResult(exitCode: 0, stdout: stdout, stderr: '')
              : null,
        ),
      );
      addTearDown(container.dispose);
      final checks = await container
          .read(systemHealthServiceProvider)
          .checkAll();
      return checks.firstWhere((c) => c.id == SystemCheckId.diskSpace);
    }

    String output({required int freeBytes, required int totalBytes}) =>
        Platform.isWindows
        ? '${kDiskMarker}free=$freeBytes\n${kDiskMarker}total=$totalBytes\n'
        : 'Filesystem 1024-blocks Used Available Capacity Mounted\n'
              '/dev/sda1 ${totalBytes ~/ 1024} '
              '${(totalBytes - freeBytes) ~/ 1024} ${freeBytes ~/ 1024} 0% /\n';

    test('plenty of room is healthy and still shows the number', () async {
      final check = await diskCheck(
        output(freeBytes: 400 * 1024 * 1024 * 1024, totalBytes: 512 * 1024 * 1024 * 1024),
      );

      expect(check.level, HealthLevel.healthy);
      expect(check.summary, contains('free of'));
      expect(check.remedy, isNull);
    });

    test('97% used — the reading this machine actually took', () async {
      final check = await diskCheck(
        output(
          freeBytes: 15 * 1024 * 1024 * 1024,
          totalBytes: 512 * 1024 * 1024 * 1024,
        ),
      );

      expect(check.level, HealthLevel.failed);
      expect(check.summary, contains('97% used'));
      // The reason this is worth a row: it arrives disguised as other faults.
      expect(check.remedy, contains('names anything but the disk'));
    });

    test('a volume that could not be measured shows no number', () async {
      final check = await diskCheck('nothing useful');

      expect(check.level, HealthLevel.unknown);
      expect(check.summary, contains('no number is shown for it'));
    });
  });

  test('Android is skipped honestly when there is no SDK', () async {
    final container = containerWith(
      probe: probeReturning(ProcessHandleScript.replies(initializeResult)),
    );
    addTearDown(container.dispose);

    final checks = await container.read(systemHealthServiceProvider).checkAll();
    final android = checks.firstWhere(
      (c) => c.id == SystemCheckId.androidTooling,
    );

    // Not healthy. Nothing was measured, so nothing is claimed.
    expect(android.level, HealthLevel.unknown);
    expect(android.summary, contains('No Android SDK on this host'));
  });

  group('the report itself', () {
    test('starts with nothing checked and says so', () {
      const report = SystemHealthReport.notChecked;
      expect(report.hasRun, isFalse);
      expect(report.checkedAt, isNull);
      // Before anything has run, the worst thing known is that nothing is
      // known — never "healthy".
      expect(report.worst, HealthLevel.unknown);
      expect(report.checkFor(SystemCheckId.mcpBridge), isNull);
    });

    test('unknown outranks healthy but not warning', () {
      // The ordering that stops an unmeasured machine being drawn green.
      expect(HealthLevel.unknown.index, greaterThan(HealthLevel.healthy.index));
      expect(HealthLevel.unknown.index, lessThan(HealthLevel.warning.index));
      expect(HealthLevel.warning.index, lessThan(HealthLevel.failed.index));
    });

    test('the worst finding wins, across checks and environments', () {
      final report = SystemHealthReport(
        checkedAt: DateTime.utc(2026, 9, 3),
        checks: const [
          SystemCheck(
            id: SystemCheckId.mcpBridge,
            title: 'MCP bridge',
            level: HealthLevel.healthy,
            summary: 'ok',
          ),
        ],
        environments: [
          EnvironmentHealth(
            environment: windowsEnv(),
            level: HealthLevel.failed,
            summary: 'no git',
            installations: const [],
          ),
        ],
      );

      expect(report.worst, HealthLevel.failed);
    });

    test('a refresh stamps the time the checks ran', () async {
      final container = containerWith(
        probe: probeReturning(ProcessHandleScript.replies(initializeResult)),
      );
      addTearDown(container.dispose);

      expect(container.read(systemHealthProvider).hasRun, isFalse);
      await container.read(systemHealthProvider.notifier).refresh();

      final report = container.read(systemHealthProvider);
      expect(report.hasRun, isTrue);
      expect(report.running, isFalse);
      expect(report.checkFor(SystemCheckId.mcpBridge), isNotNull);
    });
  });
}

/// How a scripted bridge process behaves.
class ProcessHandleScript {
  ProcessHandleScript._({this.reply, this.startError});

  /// The process starts and writes [line] to stdout.
  factory ProcessHandleScript.replies(String line) =>
      ProcessHandleScript._(reply: line);

  /// The process starts and never says anything.
  factory ProcessHandleScript.silent() => ProcessHandleScript._();

  /// The process could not be started at all.
  factory ProcessHandleScript.failsToStart(Object error) =>
      ProcessHandleScript._(startError: error);

  final String? reply;
  final Object? startError;

  void drive(FakeProcessHandle handle) {
    final line = reply;
    if (line != null) Future.microtask(() => handle.emitStdout(line));
  }
}
