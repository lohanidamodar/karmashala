import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_mcp/access.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/mcp/session_mcp.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/second_local_address.dart';

/// The config file a launching session is handed, and whose namespace its path
/// is spelled in.
///
/// The file is written by the Windows app; the agent that opens it may be
/// running inside a WSL distribution, where `C:\…` is not a name for anything.
/// So the path has to be translated the way every other cross-environment path
/// in this codebase is — explicitly, with both environments in hand — and the
/// cases below are mostly about that, plus the fail-closed rules that keep a
/// launch identical to today's when there is nothing honest to hand it.
void main() async {
  // Only the WSL case needs a second bindable address; see
  // [findSecondLocalAddress].
  final secondAddress = await findSecondLocalAddress();
  final skipWsl = secondAddress == null ? noSecondAddressReason : null;

  /// The WSL case additionally translates the config file's *own* path from a
  /// Windows drive into `/mnt/...`, so the temp directory it runs in has to be
  /// on a Windows disk. On a Mac the fixture path is `/var/folders/...`, which
  /// is not a Windows path and has no `/mnt` form — the translation correctly
  /// refuses, and the case cannot run.
  final skipWslPath = Platform.isWindows
      ? skipWsl
      : 'Translates a Windows drive path into its /mnt form, so it needs a '
            'temp directory on a Windows disk.';

  late Directory tmp;
  late ProviderContainer container;

  final wslStandIn = secondAddress ?? InternetAddress.loopbackIPv4;

  Future<LauncherControlServer> startServer({
    HandshakePermissions? permissions,
    String? bridgeFile,
    String? configDirectory,
    File? Function()? bridgeExecutable,
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(FixedClock(testTime)),
        databaseProvider.overrideWithValue(db),
      ],
    );
    final server = LauncherControlServer(
      container,
      permissions: permissions,
      // Absent unless a case says otherwise, which is also the honest default:
      // nothing puts `karmashala_mcp.exe` beside the test runner, and nothing
      // currently puts it beside the installed app either.
      bridgeExecutable: bridgeExecutable ?? () => null,
    );
    await server.start(
      bridgeFilePath: p.join(tmp.path, bridgeFile ?? 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
      sessionConfigDirectory: configDirectory ?? p.join(tmp.path, 'mcp'),
      wslHostAddress: () async => wslStandIn,
      // The stand-in is injected, so the second listener is wanted on any host.
      hostCanHaveWsl: true,
    );
    addTearDown(() async {
      await server.stop();
      container.dispose();
    });
    return server;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_session_mcp_');
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
        agentConfigPathFor(
          r'C:\Users\dlohani\AppData\Roaming\x\s.json',
          EnvironmentKind.windowsNative,
        ),
        r'C:\Users\dlohani\AppData\Roaming\x\s.json',
      );
    });

    test('a WSL agent is given the drive mount', () {
      expect(
        agentConfigPathFor(
          r'C:\Users\dlohani\AppData\Roaming\x\s.json',
          EnvironmentKind.wsl,
        ),
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

    test(
      'an SSH agent is given nothing, because the file is not on its disk',
      () {
        expect(agentConfigPathFor(r'C:\x\s.json', EnvironmentKind.ssh), isNull);
      },
    );
  });

  /// Which **transport** the entry in that file describes, which is a different
  /// question from what the file is called.
  ///
  /// A WSL2 distribution has its own network namespace: `127.0.0.1` there is
  /// its own loopback, and the host side of the Hyper-V virtual switch — the
  /// one address of ours it can name — accepts the connection and resets the
  /// first data segment on the owner's machine, for a bare PowerShell listener
  /// as readily as for this app. So an agent there is pointed at the stdio
  /// bridge instead, which is a *Windows* program launched over WSL interop and
  /// therefore reaches this process the way any local one does.
  ///
  /// **Every case below also pins what must not change.** The bridge is offered
  /// to `EnvironmentKind.wsl` and to nothing else, so a Windows pane, a macOS
  /// host and a Linux host keep the loopback URL they have today whether or not
  /// a bridge executable happens to exist beside the app.
  group('which transport the entry describes', () {
    /// A stand-in for `karmashala_mcp.exe` sitting beside the app.
    File bridgeAt(String name) {
      final exe = File(p.join(tmp.path, name))..writeAsStringSync('');
      return exe;
    }

    test('a WSL session is given the bridge, and no URL to dial', () async {
      final server = await startServer(
        bridgeExecutable: () => bridgeAt('karmashala_mcp.exe'),
      );

      final access = server.accessFor(
        sessionId: 's1',
        environment: wslEnv(),
        withConfigFile: true,
      )!;

      final entry = entryIn(p.join(tmp.path, 'mcp', 'session-s1.json'));
      expect(entry['type'], 'stdio');
      // Spelled the way the agent names it: `C:\…` is not a path inside a
      // distribution, and a command it cannot run is worse than no server.
      expect(entry['command'], startsWith('/mnt/'));
      expect(entry['command'], isNot(contains(r'\')));
      expect(entry['command'], endsWith('/karmashala_mcp.exe'));
      // And nothing that looks like an address, because there is none to dial
      // — not in the file, and not handed onward to build a flag out of.
      expect(entry.containsKey('url'), isFalse);
      expect(access.url, isNull);
    }, skip: skipWslPath);

    test('no credential is written into that entry', () async {
      // The HTTP form carries a per-session token in its URL because an HTTP
      // request has nothing else to identify itself with. The bridge reads the
      // handshake token from the directory this app already locks to the owner
      // and learns which session it is from `KARMASHALA_SESSION_ID`, stamped on
      // the agent process — so identity is measured off the real process tree
      // and no secret goes into a config file at all.
      final server = await startServer(
        bridgeExecutable: () => bridgeAt('karmashala_mcp.exe'),
      );

      server.accessFor(
        sessionId: 's1',
        environment: wslEnv(),
        withConfigFile: true,
      );

      final raw = File(
        p.join(tmp.path, 'mcp', 'session-s1.json'),
      ).readAsStringSync();
      expect(raw, isNot(contains(server.callers.tokenFor('s1'))));
      expect(raw, isNot(contains('token')));
    }, skip: skipWslPath);

    test('with no bridge beside the app it falls back to the URL', () async {
      // The bridge is a separate executable that may simply not be there. The
      // fallback is exactly today's behaviour — which works on a machine whose
      // switch is open, and is honestly reported as broken on one whose is not.
      final server = await startServer();

      final access = server.accessFor(
        sessionId: 's1',
        environment: wslEnv(),
        withConfigFile: true,
      )!;

      final entry = entryIn(p.join(tmp.path, 'mcp', 'session-s1.json'));
      expect(entry['type'], 'http');
      expect(entry['url'], access.url);
      expect(access.url, startsWith('http://${wslStandIn.address}:'));
    }, skip: skipWslPath);

    test('a Windows session keeps the loopback URL, bridge or not', () async {
      // The Windows-native path is not what this change is for, and a Windows
      // pane already shares this process's loopback. Asserted *with* a bridge
      // present so the selection is provably by environment and not by
      // whichever file happens to be on disk.
      final withBridge = await startServer(
        bridgeExecutable: () => bridgeAt('karmashala_mcp.exe'),
      );

      final access = withBridge.accessFor(
        sessionId: 's1',
        environment: windowsEnv(),
        withConfigFile: true,
      )!;

      final entry = entryIn(p.join(tmp.path, 'mcp', 'session-s1.json'));
      expect(entry['type'], 'http');
      expect(entry['url'], access.url);
      expect(access.url, startsWith('http://127.0.0.1:'));
    });

    test('a macOS or Linux session keeps the loopback URL, bridge or not', () async {
      // **The cross-platform guarantee, pinned.** There is no WSL on a Mac and
      // none on a Linux desktop, so `localPosix` must be untouched by every
      // part of this — no bridge, no spool, no share. It is asserted with a
      // bridge present for the same reason as the Windows case above: the
      // transport is chosen by `EnvironmentKind`, so a file appearing beside
      // the app cannot move a POSIX host onto a Windows-only path.
      final server = await startServer(
        bridgeExecutable: () => bridgeAt('karmashala_mcp'),
      );

      final access = server.accessFor(
        sessionId: 's1',
        environment: posixEnv(),
        withConfigFile: true,
      )!;

      final entry = entryIn(p.join(tmp.path, 'mcp', 'session-s1.json'));
      expect(entry['type'], 'http');
      expect(entry['url'], access.url);
      expect(access.url, startsWith('http://127.0.0.1:'));
      // And the file is named the way the agent already knows it: a POSIX host
      // shares this filesystem, so there is nothing to translate.
      expect(access.configPath, p.join(tmp.path, 'mcp', 'session-s1.json'));
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
      expect(access.url, startsWith('http://${wslStandIn.address}:'));
      // The file itself is where Windows put it, holding that URL.
      expect(
        entryIn(p.join(tmp.path, 'mcp', 'session-s1.json'))['url'],
        access.url,
      );
    }, skip: skipWslPath);

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
        server.callers.sessionFor(Uri.parse(one.url!).pathSegments.last),
        's1',
      );
      expect(
        server.callers.sessionFor(Uri.parse(two.url!).pathSegments.last),
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
      final server = await startServer(permissions: _RefusingDirectoryOnly());

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

    test(
      'a stale config from a previous run never reaches a new session',
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
        expect(
          entryIn(access.configPath!)['url'],
          isNot(contains('dead-token')),
        );
      },
    );
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
