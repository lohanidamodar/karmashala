import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/logging/app_logger.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/mcp/handshake_file_permissions.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/mcp/session_mcp.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The config file a launching session is handed, and whose namespace its path
/// is spelled in.
///
/// The file is written by the Windows app; the agent that opens it may be
/// running inside a WSL distribution, where `C:\…` is not a name for anything.
/// So the path has to be translated the way every other cross-environment path
/// in this codebase is — explicitly, with both environments in hand — and the
/// cases below are mostly about that, plus the fail-closed rules that keep a
/// launch identical to today's when there is nothing honest to hand it.
void main() {
  late Directory tmp;
  late ProviderContainer container;

  final wslStandIn = InternetAddress('127.0.0.2');

  Future<LauncherControlServer> startServer({
    HandshakePermissions? permissions,
    String? bridgeFile,
    String? configDirectory,
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(FixedClock(testTime)),
        databaseProvider.overrideWithValue(db),
      ],
    );
    final server = LauncherControlServer(container, permissions: permissions);
    await server.start(
      bridgeFilePath: p.join(tmp.path, bridgeFile ?? 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
      sessionConfigDirectory: configDirectory ?? p.join(tmp.path, 'mcp'),
      wslHostAddress: () async => wslStandIn,
    );
    addTearDown(() async {
      await server.stop();
      container.dispose();
    });
    return server;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('chitra_session_mcp_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
  });

  /// The `karmashala` server entry out of a written config file.
  Map<String, Object?> entryIn(String windowsPath) {
    final config =
        jsonDecode(File(windowsPath).readAsStringSync())
            as Map<String, Object?>;
    return (config['mcpServers']! as Map<String, Object?>)['karmashala']!
        as Map<String, Object?>;
  }

  group('the name the file has in the agent\'s own namespace', () {
    test('a Windows agent is given the path as written', () {
      expect(
        agentConfigPathFor(r'C:\Users\dlohani\AppData\Roaming\x\s.json',
            EnvironmentKind.windowsNative),
        r'C:\Users\dlohani\AppData\Roaming\x\s.json',
      );
    });

    test('a WSL agent is given the drive mount', () {
      expect(
        agentConfigPathFor(r'C:\Users\dlohani\AppData\Roaming\x\s.json',
            EnvironmentKind.wsl),
        '/mnt/c/Users/dlohani/AppData/Roaming/x/s.json',
      );
    });

    test('a path that cannot be spelled there is refused, not guessed', () {
      // A roaming profile can put the application-support directory on a UNC
      // share, and `\\server\share` has no `/mnt/` form. Handing an agent a
      // path it cannot open is worse than handing it nothing.
      expect(
        agentConfigPathFor(r'\\server\share\x\s.json', EnvironmentKind.wsl),
        isNull,
      );
    });

    test('an SSH agent is given nothing, because the file is not on its disk',
        () {
      expect(
        agentConfigPathFor(r'C:\x\s.json', EnvironmentKind.ssh),
        isNull,
      );
    });
  });

  group('the file an agent is asked to open', () {
    test('a Windows session is given a Windows path', () async {
      final server = await startServer();

      final access = server.accessFor(
        sessionId: 's1',
        environment: windowsEnv(),
        withConfigFile: true,
      )!;

      expect(access.configPath, p.join(tmp.path, 'mcp', 'session-s1.json'));
      expect(entryIn(access.configPath!)['url'], access.url);
      expect(access.url, startsWith('http://127.0.0.1:'));
    });

    test('a WSL session is given the path in its own namespace', () async {
      // The file is on the Windows disk either way; only its *name* differs,
      // and `C:\…` names nothing inside a distribution.
      final server = await startServer();

      final access = server.accessFor(
        sessionId: 's1',
        environment: wslEnv(),
        withConfigFile: true,
      )!;

      expect(access.configPath, startsWith('/mnt/'));
      expect(access.configPath, isNot(contains(r'\')));
      expect(access.configPath, endsWith('/mcp/session-s1.json'));
      // And the URL inside it is the one WSL can actually dial.
      expect(access.url, startsWith('http://127.0.0.2:'));
      // The file itself is where Windows put it, holding that URL.
      expect(
        entryIn(p.join(tmp.path, 'mcp', 'session-s1.json'))['url'],
        access.url,
      );
    });

    test('one file per session, each speaking only for its own', () async {
      // The URL in the file is the identity, so a shared config would be two
      // agents with one voice.
      final server = await startServer();

      final one = server.accessFor(
        sessionId: 's1',
        environment: windowsEnv(),
        withConfigFile: true,
      )!;
      final two = server.accessFor(
        sessionId: 's2',
        environment: windowsEnv(),
        withConfigFile: true,
      )!;

      expect(one.configPath, isNot(two.configPath));
      expect(
        server.callers.sessionFor(Uri.parse(one.url).pathSegments.last),
        's1',
      );
      expect(
        server.callers.sessionFor(Uri.parse(two.url).pathSegments.last),
        's2',
      );
    });

    test('an agent whose convention needs no file gets none', () async {
      // Codex takes the URL on its command line, so writing a file it will
      // never open would be litter holding a live credential.
      final server = await startServer();

      final access = server.accessFor(
        sessionId: 's1',
        environment: windowsEnv(),
        withConfigFile: false,
      )!;

      expect(access.configPath, isNull);
      expect(access.url, isNotEmpty);
      expect(Directory(p.join(tmp.path, 'mcp')).listSync(), isEmpty);
    });

    test('a config is rewritten on every launch', () async {
      final server = await startServer();
      final path = server
          .accessFor(
            sessionId: 's1',
            environment: windowsEnv(),
            withConfigFile: true,
          )!
          .configPath!;
      File(path).writeAsStringSync('{"mcpServers":{}}');

      final again = server.accessFor(
        sessionId: 's1',
        environment: windowsEnv(),
        withConfigFile: true,
      )!;

      expect(entryIn(again.configPath!)['url'], again.url);
    });
  });

  group('nothing rather than something broken', () {
    test('a session over SSH is offered nothing at all', () async {
      final server = await startServer();

      expect(
        server.accessFor(
          sessionId: 's1',
          environment: sshEnvFixture(),
          withConfigFile: true,
        ),
        isNull,
      );
    });

    test('nothing when the endpoint has no credential', () async {
      final server = await startServer(permissions: _RefusingPermissions());

      expect(
        server.accessFor(
          sessionId: 's1',
          environment: windowsEnv(),
          withConfigFile: true,
        ),
        isNull,
      );
    });

    test('no file when its directory could not be locked down', () async {
      // The file holds a credential for the app's whole tool surface. If the
      // owner-only ACL did not apply there is no boundary to put it behind, so
      // it is not written and the launch is the one that happened yesterday.
      final server = await startServer(
        permissions: _RefusingDirectoryOnly(),
      );

      expect(
        server.accessFor(
          sessionId: 's1',
          environment: windowsEnv(),
          withConfigFile: true,
        ),
        isNull,
      );
      // The URL itself is still fine — an agent that takes it on the command
      // line is unaffected.
      expect(
        server
            .accessFor(
              sessionId: 's1',
              environment: windowsEnv(),
              withConfigFile: false,
            )
            ?.url,
        isNotNull,
      );
    });

    test('a stale config from a previous run never reaches a new session',
        () async {
      final directory = p.join(tmp.path, 'mcp');
      Directory(directory).createSync(recursive: true);
      final stale = File(p.join(directory, 'session-s1.json'))
        ..writeAsStringSync(
          '{"mcpServers":{"karmashala":{"type":"http",'
          '"url":"http://127.0.0.1:1/mcp/dead-token"}}}',
        );

      final server = await startServer(configDirectory: directory);

      // Gone at startup, not merely overwritten later: a session that is never
      // launched again must not leave a file naming a port this run reused.
      expect(stale.existsSync(), isFalse);
      final access = server.accessFor(
        sessionId: 's1',
        environment: windowsEnv(),
        withConfigFile: true,
      )!;
      expect(entryIn(access.configPath!)['url'], isNot(contains('dead-token')));
    });
  });

  test('the launcher reads the wiring off a provider it does not own', () async {
    // The control server is built in the lifecycle owner, not in a provider, so
    // this is how a launch finds it — and finds nothing when nothing is up,
    // which is what makes "the server is down" launch a session unchanged.
    final bare = ProviderContainer();
    addTearDown(bare.dispose);
    expect(bare.read(sessionMcpProvider), isNull);

    final server = await startServer();
    expect(container.read(sessionMcpProvider), same(server));

    await server.stop();
    expect(container.read(sessionMcpProvider), isNull);
  });
}

/// Hardening that never applies, so nothing privileged is minted or served.
class _RefusingPermissions extends HandshakePermissions {
  @override
  Future<bool> restrictDirectory(Directory dir, {AppLogger? logger}) async =>
      false;

  @override
  Future<bool> restrictFile(File file, {AppLogger? logger}) async => false;
}

/// Files can be locked down, directories cannot — which leaves the endpoint
/// fully up and only the config directory unusable.
class _RefusingDirectoryOnly extends HandshakePermissions {
  var _first = true;

  @override
  Future<bool> restrictDirectory(Directory dir, {AppLogger? logger}) async {
    // The socket directory is asked for first and must succeed, or the whole
    // privileged surface is withheld and this test proves nothing.
    if (_first) {
      _first = false;
      return const SystemHandshakePermissions().restrictDirectory(
        dir,
        logger: logger,
      );
    }
    return false;
  }

  @override
  Future<bool> restrictFile(File file, {AppLogger? logger}) =>
      const SystemHandshakePermissions().restrictFile(file, logger: logger);
}
