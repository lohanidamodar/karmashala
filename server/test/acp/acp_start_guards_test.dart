import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_host/src/acp/acp_runtimes.dart';
import 'package:karmashala_host/src/acp/acp_session_runtime.dart';
import 'package:karmashala_host/src/acp/acp_transport.dart';
import 'package:karmashala_host/src/acp/acp_version_probe.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import 'acp_fixture.dart';

/// Two ways an ACP start used to hang without a word, seen live: an
/// installation recorded as `npx` with nothing to run (npm then waits on a
/// terminal nobody has), and an agent that never answers `initialize`.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 12);

  AgentInstallation installation(
    String path, {
    List<String> leading = const [],
    String? version,
  }) => AgentInstallation(
    id: 'i1',
    agentId: 'gemini-cli',
    executable: EnvironmentPath(environmentId: 'wsl:arch', path: path),
    createdAt: t0,
    version: version,
    leadingArguments: leading,
  );

  test('an argument declared from a version is passed only to that version '
      'or later', () {
    const spec = AcpLaunchSpec(
      arguments: ['-p'],
      versionedArguments: [
        AcpVersionedArgument(
          since: '2.1.0',
          arguments: ['--new-flag'],
          evidence: 'read off --help of 2.1.0',
        ),
      ],
    );
    List<String> argv(String? version) => acpArgumentsFor(
      installation('/bin/agent', version: version),
      spec,
      linux: false,
    );
    expect(argv('2.1.0 (Agent)'), ['-p', '--new-flag']);
    expect(argv('2.0.9'), ['-p']);
    expect(argv(null), ['-p']);
  });

  group('acpArgumentsFor', () {
    const spec = AcpLaunchSpec(
      arguments: ['--acp'],
      npxPackage: '@example/agent',
    );

    test('keeps what discovery put in front of the mode arguments', () {
      expect(
        acpArgumentsFor(
          installation('/usr/bin/npx', leading: ['-y', '@example/agent@1']),
          spec,
          linux: true,
        ),
        ['-y', '@example/agent@1', '--acp'],
      );
      expect(
        acpArgumentsFor(
          installation('/home/me/.local/bin/agent'),
          spec,
          linux: true,
        ),
        ['--acp'],
      );
    });

    test('an npx recorded with nothing in front runs the declared package', () {
      for (final path in ['/usr/sbin/npx', r'C:\nodejs\npx.cmd', 'NPX.EXE']) {
        expect(acpArgumentsFor(installation(path), spec, linux: false), [
          '-y',
          '@example/agent',
          '--acp',
        ], reason: path);
      }
    });

    Matcher refusedForRescan = throwsA(
      isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('rescan agents'),
      ),
    );

    test('a stale npx row of an agent that now runs its own binary is '
        'refused in words, never run as npx app-server', () {
      final codex = codexAcpDescriptor.acp!;
      final stale = installation(
        r'C:\nodejs\npx.cmd',
        leading: ['-y', '@agentclientprotocol/codex-acp'],
      );
      expect(
        () => acpArgumentsFor(stale, codex, linux: false),
        refusedForRescan,
      );
      // Recorded before leading arguments were kept: still npx, still refused.
      expect(
        () => acpArgumentsFor(installation('/usr/bin/npx'), codex, linux: true),
        refusedForRescan,
      );
      // The binary a rescan finds runs as the spec says.
      expect(
        acpArgumentsFor(
          installation(r'C:\codex\codex.exe'),
          codex,
          linux: false,
        ),
        ['app-server'],
      );
    });

    test('an npx row runs only the spec\'s own package', () {
      expect(
        () => acpArgumentsFor(
          installation('/usr/bin/npx', leading: ['-y', '@other/agent']),
          spec,
          linux: true,
        ),
        refusedForRescan,
      );
      expect(
        acpArgumentsFor(
          installation('/usr/bin/npx', leading: ['-y', '@example/agent']),
          spec,
          linux: true,
        ),
        ['-y', '@example/agent', '--acp'],
      );
      // A spec that names no package never runs a package an npx row names.
      expect(
        () => acpArgumentsFor(
          installation('/usr/bin/npx', leading: ['-y', '@example/agent']),
          const AcpLaunchSpec(arguments: ['--acp']),
          linux: true,
        ),
        refusedForRescan,
      );
    });

    test(
      'a person\'s own agent whose command is npx runs as they wrote it',
      () {
        const own = AcpLaunchSpec(arguments: ['-y', 'their-agent', '--acp']);
        expect(
          acpArgumentsFor(installation('/usr/bin/npx'), own, linux: true),
          ['-y', 'their-agent', '--acp'],
        );
      },
    );

    test('the login and the version read build their argv the same way', () {
      final environment = ExecutionEnvironment(
        id: 'wsl:arch',
        kind: EnvironmentKind.wsl,
        name: 'arch',
        wslDistribution: 'arch',
        createdAt: t0,
      );
      expect(
        () => acpProbeRequest(
          installation(
            '/usr/bin/npx',
            leading: ['-y', '@agentclientprotocol/codex-acp'],
          ),
          codexAcpDescriptor.acp!,
          environment,
          '/tmp',
        ),
        refusedForRescan,
      );
      expect(
        acpProbeRequest(
          installation('/usr/bin/codex'),
          codexAcpDescriptor.acp!,
          environment,
          '/tmp',
        ).arguments,
        ['app-server'],
      );
    });

    test('Linux-only arguments follow the mode arguments on Linux alone', () {
      const withLinux = AcpLaunchSpec(
        arguments: ['--acp'],
        linuxArguments: ['--uid='],
      );
      expect(
        acpArgumentsFor(installation('/opt/agent'), withLinux, linux: true),
        ['--acp', '--uid='],
      );
      expect(
        acpArgumentsFor(installation(r'C:\agent.exe'), withLinux, linux: false),
        ['--acp'],
      );
      // A WSL distribution is Linux; the local host only when it is.
      expect(
        AcpLaunchSpec.runsOnLinux(EnvironmentKind.wsl, hostIsLinux: false),
        isTrue,
      );
      expect(
        AcpLaunchSpec.runsOnLinux(
          EnvironmentKind.localPosix,
          hostIsLinux: true,
        ),
        isTrue,
      );
      expect(
        AcpLaunchSpec.runsOnLinux(
          EnvironmentKind.localPosix,
          hostIsLinux: false,
        ),
        isFalse,
      );
      expect(
        AcpLaunchSpec.runsOnLinux(
          EnvironmentKind.windowsNative,
          hostIsLinux: true,
        ),
        isFalse,
      );
    });

    test('a person\'s own npx row, which names its package itself, is left '
        'as given', () {
      // A row from the registry: command `npx`, arguments carrying the
      // package; it declares no npxPackage of its own.
      expect(
        acpArgumentsFor(
          installation('/usr/sbin/npx'),
          const AcpLaunchSpec(arguments: ['-y', '@github/copilot', '--acp']),
          linux: true,
        ),
        ['-y', '@github/copilot', '--acp'],
      );
    });
  });

  group('startPatience', () {
    late AppDatabase database;
    late Directory temp;

    setUp(() {
      database = AppDatabase.memory();
      database.execute('PRAGMA foreign_keys = OFF;');
      temp = Directory.systemTemp.createTempSync('acp_start_guards');
    });

    tearDown(() {
      database.close();
      temp.deleteSync(recursive: true);
    });

    test('an agent that never answers initialize fails the start in words, '
        'with what it wrote to stderr', () async {
      final silence = StreamController<List<int>>();
      final exit = Completer<int>();
      var killed = false;
      final runtime = AcpSessionRuntime(
        id: 'karmashala_s1',
        sessionId: 's1',
        agentId: 'gemini-cli',
        agentName: 'Gemini CLI',
        spec: const AcpLaunchSpec(arguments: ['--acp']),
        workingDirectory: temp.path,
        spawn: () async => AcpTransport.streams(
          output: silence.stream,
          input: _Discarding(),
          exitCode: exit.future,
          errorLines: Stream.value(
            'npm warn exec The following package was not found',
          ),
          kill: () async {
            killed = true;
            if (!exit.isCompleted) exit.complete(137);
            await silence.close();
          },
        ),
        messages: SessionMessageDao(database),
        host: RecordingHost(),
        startPatience: const Duration(milliseconds: 150),
        stopPatience: const Duration(milliseconds: 50),
      );

      await expectLater(
        runtime.start(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Gemini CLI could not be started'),
              contains('did not answer initialize within'),
              contains('npm warn exec'),
            ),
          ),
        ),
      );
      expect(runtime.lifecycle.hasEnded, isTrue);
      // The kill follows the failure, not the other way round: the start
      // throws first and tears down behind it.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(killed, isTrue, reason: 'the hung process is not left behind');
    });

    test('a spawn that fails keeps the agent\'s variables out of the words '
        'the start fails with', () async {
      final runtimes = AcpRuntimes(
        messages: SessionMessageDao(database),
        host: RecordingHost(),
        runnerFor: (_) => FakeCommandRunner(
          throwError: const ProcessException('wsl.exe', [
            '--',
            'env',
            'GEMINI_API_KEY=k-123',
            'KARMASHALA_SESSION_ID=s1',
          ], 'The system cannot find the file specified.'),
        ),
      );
      final runtime = runtimes.start(
        AcpSessionStart(
          sessionId: 's1',
          hostSessionId: 'karmashala_s1',
          agentId: 'antigravity-acp',
          agentName: 'Antigravity',
          spec: const AcpLaunchSpec(),
          executable: '/home/me/agy',
          arguments: const [],
          directory: EnvironmentPath(environmentId: 'local', path: temp.path),
          variables: const {
            'GEMINI_API_KEY': 'k-123',
            'KARMASHALA_SESSION_ID': 's1',
          },
        ),
      );
      await expectLater(
        runtime.start(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('cannot find the file'),
              contains('KARMASHALA_SESSION_ID=s1'),
              isNot(contains('k-123')),
            ),
          ),
        ),
      );
    });
  });
}

/// A sink that takes what the client writes and keeps nothing.
class _Discarding implements StreamSink<List<int>> {
  final _done = Completer<void>();

  @override
  void add(List<int> event) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}
