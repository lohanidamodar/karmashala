@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_host/host_paths.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';

/// A **real** `karmashala_host serve`, built from this tree, started by the
/// supervisor through the launch's own path (`LocalHostSessionAccess`), then
/// SIGTERM'd — as it was live on 2026-09-25 with the app open. A new one must
/// come up the same way, with the same arguments, and nothing outside the
/// test's own temp folders is touched: its own host directory, data folder,
/// and ephemeral MCP and companion ports.
void main() {
  test(
    'a real host killed under the supervisor is started again by it',
    () async {
      final home = Directory.systemTemp.createTempSync('ks-sup-live');
      final started = <int>{};
      addTearDown(() {
        for (final pid in started) {
          Process.killPid(pid, ProcessSignal.sigkill);
        }
        try {
          home.deleteSync(recursive: true);
        } on FileSystemException {
          // The OS's problem after this.
        }
      });
      // Where `LocalHostExecutable` finds a debug build.
      final repository = '${home.path}/repo';
      await _buildHost('$repository/server/build/cli/live');

      final hostDirectory = Directory('${home.path}/h')..createSync();
      final data = Directory('${home.path}/data')..createSync();
      final access = LocalHostSessionAccess(
        paths: HostPaths(hostDirectory),
        executable: LocalHostExecutable(
          executableDirectory: '${home.path}/no-app-here',
          repositoryRoot: repository,
        ),
        serveEnvironment: {
          kHostDirectoryEnvironmentVariable: hostDirectory.path,
          'HOME': home.path,
        },
        dataDirectory: () async => data.path,
        serveFlags: const ['--mcp-port=0', '--companion-port=0'],
      );
      final supervisor = LocalHostSupervisor(
        access: access,
        backoff: const [
          Duration(milliseconds: 200),
          Duration(milliseconds: 500),
          Duration(seconds: 1),
        ],
      );
      addTearDown(supervisor.dispose);

      final first = await supervisor.start();
      expect(first?.isReady, isTrue, reason: first?.reason);
      expect(first!.restartedByUs, isTrue);
      final firstPid = first.hostPid!;
      started.add(firstPid);
      expect(
        File('${data.path}/karmashala.sqlite').existsSync(),
        isTrue,
        reason: 'serve was not given the data folder',
      );

      final restarted = supervisor.restarted.first;
      expect(Process.killPid(firstPid), isTrue);
      final second = await restarted.timeout(const Duration(seconds: 30));
      started.add(second.hostPid!);

      expect(second.isReady, isTrue, reason: second.reason);
      expect(second.restartedByUs, isTrue);
      expect(second.hostPid, isNot(firstPid));
      expect(supervisor.state.phase, HostSupervisionPhase.running);
      // It answers, and is the one the supervisor says.
      expect((await access.observe()).hostPid, second.hostPid);
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: Platform.isWindows
        ? 'a SIGTERM is how the host was lost; Windows has no such signal'
        : false,
  );
}

/// Builds the host bundle from this tree into [output], the way the release
/// does (`dart build cli`): the executable finds its SQLite at `../lib`.
Future<void> _buildHost(String output) async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final dart = flutterRoot == null
      ? 'dart'
      : '$flutterRoot/bin/dart${Platform.isWindows ? '.bat' : ''}';
  final result = await Process.run(dart, [
    'build',
    'cli',
    '-t',
    'bin/karmashala_host.dart',
    '-o',
    output,
  ], workingDirectory: _hostPackage());
  if (result.exitCode != 0) {
    throw StateError('host build failed: ${result.stdout}${result.stderr}');
  }
  final built = File('$output/bundle/bin/${LocalHostExecutable.fileName}');
  expect(built.existsSync(), isTrue, reason: 'no ${built.path}');
}

/// `server/`, from wherever the runner started this package's tests.
String _hostPackage() {
  for (final candidate in ['../../server', 'server']) {
    if (File('$candidate/bin/karmashala_host.dart').existsSync()) {
      return Directory(candidate).absolute.path;
    }
  }
  throw StateError('server/ not found from ${Directory.current.path}');
}
