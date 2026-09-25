import 'dart:io';

import 'package:test/test.dart';
import 'package:agent_cli/src/agents/domain/agent_ids.dart';
import 'package:agent_cli/src/agents/codex/codex_app_server_client.dart';
import 'package:agent_cli/src/agents/adapter/store_server_launch.dart';
import 'package:agent_cli/src/agents/codex/codex_app_server_reader.dart';
import 'package:agent_cli/src/agents/codex/codex_store_reader.dart';
import 'package:agent_cli/src/cli_detection/domain/detected_session.dart';
import 'package:agent_cli/src/environments/environment_kind.dart';
import 'package:agent_cli/src/environments/execution_environment.dart';
import 'package:path/path.dart' as p;

import '../support/fake_codex_app_server.dart';
import '../support/temp_directory.dart';

/// **Codex sessions read from `thread/list` rather than from the rollouts.**
///
/// Nothing here spawns `codex`, touches `~/.codex` or opens a socket: the
/// transport is a [FakeCodexAppServer], and the two rollouts written to a temp
/// directory exist only so the *fallback* has something real to walk.
///
/// The rows below are the shape the real server was measured to send against
/// Codex 0.153.4 — epoch **seconds**, a `path` spelled the way the environment
/// spells it, and a `preview` that is the user's first message rather than the
/// preamble a rollout opens with.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_codex_'));
  tearDown(() => removeTempDirectory(tmp));

  final windows = ExecutionEnvironment(
    id: 'windows',
    kind: EnvironmentKind.windowsNative,
    name: 'Windows',
    createdAt: DateTime.utc(2026),
  );
  final wsl = ExecutionEnvironment(
    id: 'wsl:archlinux',
    kind: EnvironmentKind.wsl,
    name: 'archlinux',
    wslDistribution: 'archlinux',
    createdAt: DateTime.utc(2026),
  );

  /// One rollout whose first `role:user` message is the injected preamble the
  /// file walk mistakes for a preview.
  String writeRollout(String id, {required String cwd}) {
    final path = p.join(
      tmp.path,
      '.codex',
      'sessions',
      '2026',
      '09',
      '05',
      'rollout-2026-09-05T07-57-55-$id.jsonl',
    );
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        [
          '{"timestamp":"2026-09-05T07:57:55.000Z","type":"session_meta",'
              '"payload":{"id":"$id","cwd":"$cwd",'
              '"timestamp":"2026-09-05T07:57:55.000Z"}}',
          '{"type":"response_item","payload":{"type":"message","role":"user",'
              '"content":[{"type":"input_text","text":"<recommended_plugins> '
              'Here is a list of plugins that</recommended_plugins>"}]}}',
          '{"type":"response_item","payload":{"type":"message","role":"user",'
              '"content":[{"type":"input_text","text":"the real question"}]}}',
        ].join('\n'),
      );
    return path;
  }

  Map<String, Object?> row(
    String id, {
    required String cwd,
    required String path,
    String? name,
    String preview = 'the real question',
  }) => {
    'id': id,
    'name': name,
    'preview': preview,
    'cwd': cwd,
    'path': path,
    'createdAt': 1788574375,
    'updatedAt': 1788585458,
  };

  test('a Windows store maps a row straight through', () async {
    final home = p.join(tmp.path, '.codex');
    final file = writeRollout('u1', cwd: r'C:\src\repo');
    final server = FakeCodexAppServer.withThreads([
      row('u1', cwd: r'C:\src\repo', path: file, name: 'my thread'),
    ], codexHome: home);
    final reader = _readerFor(server);
    addTearDown(reader.close);

    final sessions = await reader.read(
      home,
      'windows',
      storeServer: StoreServerLaunch(
        environment: windows,
        executable: r'C:\codex.exe',
      ),
    );

    expect(sessions, hasLength(1));
    final session = sessions.single;
    expect(session.cli, AgentIds.codex);
    expect(session.sessionId, 'u1');
    expect(session.title, 'my thread');
    expect(session.preview, 'the real question');
    expect(session.cwd.path, r'C:\src\repo');
    expect(session.cwd.environmentId, 'windows');
    expect(session.storeHome, home);
    expect(session.filePath, file, reason: 'a local path needs no translation');
    expect(
      session.startedAt,
      DateTime.fromMillisecondsSinceEpoch(1788574375000, isUtc: true),
    );
    expect(
      session.modifiedAt,
      DateTime.fromMillisecondsSinceEpoch(1788585458000, isUtc: true),
    );
    expect(reader.fallbacksServed, 0);
  });

  test('a WSL store is read over the share, not inside the distro', () async {
    const home = r'\\wsl.localhost\archlinux\home\me\.codex';
    String? askedFor;
    final server = FakeCodexAppServer.withThreads([
      row(
        'u2',
        cwd: '/mnt/c/users/me/projects',
        path: '/home/me/.codex/sessions/2026/09/05/rollout-u2.jsonl',
      ),
    ], codexHome: '/home/me/.codex');
    final reader = _readerFor(
      server,
      onExpectedHome: (value) => askedFor = value,
    );
    addTearDown(reader.close);

    final session = (await reader.read(
      home,
      'wsl:archlinux',
      storeServer: StoreServerLaunch(
        environment: wsl,
        executable: '/home/me/.local/bin/codex',
      ),
    )).single;

    // `filePath` is documented as something the app can open; the server names
    // the path Codex sees, which from Windows is only reachable over the share.
    expect(
      session.filePath,
      r'\\wsl.localhost\archlinux\home\me\.codex\sessions\2026\09\05'
      r'\rollout-u2.jsonl',
    );
    // `cwd` stays in the distribution's own spelling, bound to its environment,
    // exactly as the file walk leaves it.
    expect(session.cwd.path, '/mnt/c/users/me/projects');
    expect(session.cwd.environmentId, 'wsl:archlinux');
    expect(
      askedFor,
      '/home/me/.codex',
      reason: 'the handshake is checked against the store in Codex spelling',
    );
  });

  test(
    'the preview is the server\'s, not the rollout\'s first message',
    () async {
      final home = p.join(tmp.path, '.codex');
      final file = writeRollout('u3', cwd: '/w');
      final server = FakeCodexAppServer.withThreads([
        row('u3', cwd: '/w', path: file),
      ], codexHome: home);
      final launch = StoreServerLaunch(
        environment: windows,
        executable: 'codex',
      );

      final reader = _readerFor(server);
      addTearDown(reader.close);
      final overProtocol = await reader.read(
        home,
        'windows',
        storeServer: launch,
      );
      final overFiles = await CodexStoreReader(
        cache: CodexRolloutCache(),
      ).read(home, 'windows');

      expect(overProtocol.single.preview, 'the real question');
      expect(
        overFiles.single.preview,
        startsWith('<recommended_plugins>'),
        reason: 'this is the defect: the walk reads an injected preamble',
      );
    },
  );

  test('a long preview is trimmed the way the walk trims one', () async {
    final home = p.join(tmp.path, '.codex');
    final file = writeRollout('u4', cwd: '/w');
    final server = FakeCodexAppServer.withThreads([
      row('u4', cwd: '/w', path: file, preview: 'a  b\n${'x' * 200}'),
    ], codexHome: home);
    final reader = _readerFor(server);
    addTearDown(reader.close);

    final preview = (await reader.read(
      home,
      'windows',
      storeServer: StoreServerLaunch(environment: windows, executable: 'codex'),
    )).single.preview;

    expect(preview.length, 120);
    expect(preview, startsWith('a b x'));
    expect(preview, endsWith('…'));
  });

  test('a row with no rollout path is dropped, matching the walk', () async {
    final home = p.join(tmp.path, '.codex');
    final server = FakeCodexAppServer.withThreads([
      {'id': 'u5', 'cwd': '/w'},
    ], codexHome: home);
    final reader = _readerFor(server);
    addTearDown(reader.close);

    expect(
      await reader.read(
        home,
        'windows',
        storeServer: StoreServerLaunch(
          environment: windows,
          executable: 'codex',
        ),
      ),
      isEmpty,
    );
  });

  test('no launch at all is the file walk, unchanged', () async {
    final home = p.join(tmp.path, '.codex');
    writeRollout('u6', cwd: '/w');
    final reader = _readerFor(FakeCodexAppServer.withThreads(const []));
    addTearDown(reader.close);

    final sessions = await reader.read(home, 'windows');

    expect(sessions.single.sessionId, 'u6');
    expect(reader.fallbacksServed, 1);
  });

  group('one install failing does not take the other with it', () {
    test(
      'the healthy Codex keeps the protocol, the broken one walks',
      () async {
        final home = p.join(tmp.path, '.codex');
        final file = writeRollout('u7', cwd: '/w');
        final healthy = FakeCodexAppServer.withThreads([
          row('u7', cwd: '/w', path: file, name: 'from the server'),
        ], codexHome: home);
        final reader = CodexAppServerReader(
          fallback: CodexStoreReader(cache: CodexRolloutCache()),
          openClient: (launch, expectedCodexHome) => CodexAppServerClient(
            connect: launch.environmentId == 'windows'
                ? () async => healthy
                : () async => throw const ProcessException('codex', []),
            timeout: const Duration(seconds: 5),
            expectedCodexHome: expectedCodexHome,
          ),
        );
        addTearDown(reader.close);

        final good = await reader.read(
          home,
          'windows',
          storeServer: StoreServerLaunch(
            environment: windows,
            executable: 'codex',
          ),
        );
        final broken = await reader.read(
          home,
          'wsl:archlinux',
          storeServer: StoreServerLaunch(
            environment: wsl,
            executable: '/no/such/codex',
          ),
        );

        expect(good.single.title, 'from the server');
        expect(
          broken.single.title,
          isNull,
          reason:
              'the walk reads names from session_index.jsonl, and there is '
              'none here — the point is that it still answered',
        );
        expect(broken.single.sessionId, 'u7');
        expect(reader.fallbacksServed, 1);
        expect(reader.lastFailureByEnvironment.keys, [
          'wsl:archlinux',
        ], reason: 'only the install that failed is recorded as having failed');
        expect(
          reader.lastFailureByEnvironment['wsl:archlinux']!.kind,
          CodexAppServerFailureKind.unavailable,
        );
      },
    );

    test(
      'a failed install sits out scans instead of respawning each one',
      () async {
        final home = p.join(tmp.path, '.codex');
        writeRollout('u8', cwd: '/w');
        var attempts = 0;
        final reader = CodexAppServerReader(
          fallback: CodexStoreReader(cache: CodexRolloutCache()),
          openClient: (launch, expectedCodexHome) => CodexAppServerClient(
            connect: () async {
              attempts++;
              throw const ProcessException('codex', []);
            },
            timeout: const Duration(seconds: 5),
          ),
        );
        addTearDown(reader.close);

        Future<List<DetectedSession>> scan() => reader.read(
          home,
          'windows',
          storeServer: StoreServerLaunch(
            environment: windows,
            executable: 'codex',
          ),
        );

        await scan(); // fails, and skips 1
        expect(attempts, 1);
        await scan();
        expect(attempts, 1, reason: 'the skipped scan spawns nothing');
        await scan(); // fails again, and skips 2
        expect(attempts, 2);
        await scan();
        await scan();
        expect(attempts, 2);
        await scan();
        expect(attempts, 3);
        // Every one of them still produced the sessions, off the disk.
        expect((await scan()).single.sessionId, 'u8');
      },
    );
  });
}

CodexAppServerReader _readerFor(
  FakeCodexAppServer server, {
  void Function(String? expectedCodexHome)? onExpectedHome,
}) => CodexAppServerReader(
  fallback: CodexStoreReader(cache: CodexRolloutCache()),
  openClient: (launch, expectedCodexHome) {
    onExpectedHome?.call(expectedCodexHome);
    return CodexAppServerClient(
      connect: () async => server,
      timeout: const Duration(seconds: 5),
      expectedCodexHome: expectedCodexHome,
    );
  },
);
