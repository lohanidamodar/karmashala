import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_host/src/domain/session_registry.dart';
import 'package:karmashala_host/src/flutter/server_flutter_work.dart';
import 'package:karmashala_host/src/pty/fake_pty.dart';
import 'package:karmashala_host/src/pty/pty.dart';
import 'package:karmashala_store/database.dart';

import 'fake_vm_service.dart';

export 'fake_vm_service.dart';

const String appPubspec = '''
name: demo
dependencies:
  flutter:
    sdk: flutter
flutter:
  uses-material-design: true
''';

const String packagePubspec = '''
name: demo_plugin
dependencies:
  flutter:
    sdk: flutter
''';

/// The WSL checkout most tests run in: the server is told it is on Windows,
/// so the distribution is its own to reach.
const EnvironmentPath wslProject = EnvironmentPath(
  environmentId: 'wsl:Ubuntu',
  path: '/home/me/app',
);

final DateTime fixtureNow = DateTime.utc(2026, 9, 27, 12);

/// A distribution with its own Flutter, one app at the root and a resolved
/// package cache — the ordinary case.
CommandResult healthy(CommandRequest request) {
  const ok = CommandResult(exitCode: 0, stdout: '', stderr: '');
  if (request.arguments.contains('exit 0')) return ok;
  if (request.arguments.any((a) => a.contains('command -v flutter'))) {
    return const CommandResult(
      exitCode: 0,
      stdout: '/home/me/flutter/bin/flutter\n',
      stderr: '',
    );
  }
  if (request.executable == '/home/me/flutter/bin/flutter') {
    return const CommandResult(
      exitCode: 0,
      stdout: 'Flutter 3.47.2 • channel stable\n',
      stderr: '',
    );
  }
  if (request.executable == 'find') {
    return CommandResult(
      exitCode: 0,
      stdout: '${request.arguments.first}/pubspec.yaml\n',
      stderr: '',
    );
  }
  if (request.executable == 'cat') {
    return const CommandResult(exitCode: 0, stdout: appPubspec, stderr: '');
  }
  return ok;
}

/// A runner answering from [responder], recording each request.
class ScriptedRunner implements CommandRunner {
  ScriptedRunner(this.responder, {this.environmentId = 'wsl:Ubuntu'});

  CommandResult Function(CommandRequest request) responder;

  @override
  final String environmentId;

  final requests = <CommandRequest>[];

  @override
  Future<CommandResult> run(CommandRequest request) async {
    requests.add(request);
    return responder(request);
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) =>
      Future.error(CommandException('nothing is started in a test'));
}

/// Every environment reaches [runner].
class ScriptedRunners extends CommandRunnerFactory {
  const ScriptedRunners(this.runner);

  final CommandRunner runner;

  @override
  CommandRunner forEnvironment(ExecutionEnvironment environment) => runner;
}

/// The server's Flutter work over an in-memory store, a fake pty and an
/// in-process VM service — nothing real is started.
class FlutterFixture {
  FlutterFixture({CommandResult Function(CommandRequest)? responder})
    : root = Directory.systemTemp.createTempSync('karmashala_flutter_') {
    runner = ScriptedRunner(responder ?? healthy);
    database = AppDatabase.memory();
    final at = fixtureNow.toIso8601String();
    database
      ..execute(
        'INSERT INTO execution_environments '
        '(id, kind, name, wsl_distribution, created_at) '
        "VALUES ('wsl:Ubuntu', 'wsl', 'Ubuntu', 'Ubuntu', ?);",
        [at],
      )
      ..execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        "VALUES ('box', 'ssh', 'Build box', ?);",
        [at],
      )
      ..execute(
        'INSERT INTO projects (id, name, root_environment_id, root_path, '
        "created_at) VALUES ('p1', 'Demo', 'wsl:Ubuntu', '/home/me', ?);",
        [at],
      )
      ..execute(
        'INSERT INTO repositories (id, project_id, name, environment_id, '
        "path, created_at) VALUES ('r1', 'p1', 'app', 'wsl:Ubuntu', "
        "'/home/me/app', ?);",
        [at],
      )
      ..execute(
        'INSERT INTO repositories (id, project_id, name, environment_id, '
        "path, created_at) VALUES ('rb', 'p1', 'remote', 'box', "
        "'/srv/app', ?);",
        [at],
      );
    registry = SessionRegistry(launcher: pty);
    work = build();
  }

  final Directory root;
  late final ScriptedRunner runner;
  late final AppDatabase database;
  final pty = KillablePtyLauncher();
  late final SessionRegistry registry;
  late ServerFlutterWork work;
  final told = <DataChange>[];
  final reachable = <String, FakeVmService>{};
  var _ids = 0;

  /// [hostEnvironment] and [operatingSystem] decide whether the server has a
  /// desktop; the default is a Linux box with none.
  ServerFlutterWork build({
    Map<String, String> hostEnvironment = const {},
    String operatingSystem = 'linux',
    bool windows = true,
  }) => ServerFlutterWork(
    registry: registry,
    database: database,
    tell: told.addAll,
    dataDirectory: root.path,
    hostEnvironment: hostEnvironment,
    runners: ScriptedRunners(runner),
    connect: (uri) async {
      final fake = reachable[uri.toString()];
      if (fake == null) throw const SocketException('nothing is listening');
      return fake.client;
    },
    dtdPidFiles: const DtdPidFiles([]),
    operatingSystem: operatingSystem,
    windows: windows,
    clock: () => fixtureNow,
    newId: () => 'id-${_ids++}',
  );

  /// Writes the app's `settings.v1` with [flutterSdkPaths].
  void setSdkPaths(Map<String, String> flutterSdkPaths) =>
      database.writeMetadata(
        'settings.v1',
        jsonEncode({'flutterSdkPaths': flutterSdkPaths}),
      );

  /// The fake process behind the newest hosted run.
  KillablePty get lastProcess => pty.handles.last;

  Future<void> close() async {
    await work.close();
    await registry.shutdown();
    database.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

/// A fake process that ends when signalled, as a real one would.
class KillablePty extends FakePtyHandle {
  KillablePty(super.pid, super.request);

  @override
  void kill([int signal = 15]) {
    super.kill(signal);
    finish(128 + signal);
  }
}

class KillablePtyLauncher implements PtyLauncher {
  final started = <PtySpawnRequest>[];
  final handles = <KillablePty>[];

  @override
  PtyHandle start(PtySpawnRequest request) {
    started.add(request);
    final handle = KillablePty(1000 + handles.length, request);
    handles.add(handle);
    return handle;
  }
}

/// Lets queued microtasks and the timers they set run.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));
