import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/devices/application/device_claims.dart';
import 'package:karmashala/src/features/devices/application/device_providers.dart';
import 'package:karmashala/src/features/devices/domain/device_claim.dart';
import 'package:karmashala/src/features/devices/domain/android_device.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import 'device_claims_test.dart' show MovableClock;

/// The device lock, driven the way two agents would actually collide with each
/// other: two MCP callers, each holding its own per-session credential, both
/// reaching for one emulator over the real endpoint.
///
/// Nothing here is timed. The clock moves because a test moved it.
const _sdkRoot = r'C:\sdk';
const _adbPath = r'C:\sdk\platform-tools\adb.exe';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows-native', path: _sdkRoot),
  adb: EnvironmentPath(environmentId: 'windows-native', path: _adbPath),
);

const _dumpXml =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<hierarchy rotation="0">'
    '<node index="0" class="android.widget.FrameLayout" '
    'package="com.example.app" bounds="[0,0][1080,2400]">'
    '<node index="0" text="Sign in" resource-id="com.example.app:id/signin" '
    'class="android.widget.Button" package="com.example.app" '
    'clickable="true" enabled="true" bounds="[300,700][780,860]" />'
    '</node>'
    '</hierarchy>';

void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;
  late LauncherControlServer server;
  late FakeCommandRunner adb;
  late MovableClock clock;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_device_lock_');
    db = AppDatabase.memory();
    clock = MovableClock(testTime);
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), clock);
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db)
      ..insert(session(id: 's1', title: 'Fix the login flow'))
      ..insert(session(id: 's2', title: 'Check the release build'));

    adb = FakeCommandRunner(
      responder: (request) {
        final args = request.arguments;
        if (args.contains('devices')) {
          return const CommandResult(
            exitCode: 0,
            stdout:
                'List of devices attached\n'
                'emulator-5554  device product:sdk model:Pixel transport_id:7\n',
            stderr: '',
          );
        }
        if (args.contains('wm')) {
          return const CommandResult(
            exitCode: 0,
            stdout: 'Physical size: 1080x2400',
            stderr: '',
          );
        }
        if (args.contains('uiautomator')) {
          return const CommandResult(
            exitCode: 0,
            stdout: 'UI hierchary dumped to: /data/local/tmp/x.xml',
            stderr: '',
          );
        }
        if (args.contains('cat')) {
          return const CommandResult(
            exitCode: 0,
            stdout: _dumpXml,
            stderr: '',
          );
        }
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      },
    );

    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: adb),
        ),
        androidSdkProvider.overrideWith((ref) => _sdk()),
        clockProvider.overrideWithValue(clock),
      ],
    );
    await container.read(androidSdkProvider.future);
    server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
    );
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Map<String, Object?> handshake() =>
      jsonDecode(File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync())
          as Map<String, Object?>;

  /// One `tools/call` over the endpoint. [asSession] is the identity the
  /// *transport* establishes — the per-session credential an agent's own MCP
  /// config carries, which is the only thing a model cannot forge.
  Future<({bool isError, String text})> callAs(
    String? asSession,
    String name, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final json = handshake();
    final credential = asSession == null
        ? json['mcpToken']! as String
        : server.callers.tokenFor(asSession);
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${json['port']}/mcp/$credential'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': <String, Object?>{'name': name, 'arguments': arguments},
        }),
      );
      final response = await request.close();
      final body =
          jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, Object?>;
      final result = body['result'] as Map<String, Object?>?;
      if (result == null) {
        return (isError: true, text: jsonEncode(body['error']));
      }
      // The first *text* block, not the first block: device_screenshot leads
      // with the image.
      final text = [
        for (final block in result['content']! as List<Object?>)
          if ((block! as Map<String, Object?>)['text'] case final String line)
            line,
      ].join('\n');
      return (isError: result['isError'] == true, text: text);
    } finally {
      client.close(force: true);
    }
  }

  group('two agents, one phone', () {
    test('the second caller is refused, and told who is driving', () async {
      final first = await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      expect(first.isError, isFalse, reason: first.text);

      final second = await callAs('s2', 'device_tap', {'x': 100, 'y': 100});

      expect(second.isError, isTrue);
      // Named, not merely refused: the title a reader would recognise, the id
      // they can act on, and the device itself.
      expect(second.text, contains('Fix the login flow'));
      expect(second.text, contains('s1'));
      expect(second.text, contains('emulator-5554'));
      // And a way out that does not depend on anybody noticing.
      expect(second.text, contains('lapses on its own'));
    });

    test('every acting tool is refused, not only the tap', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});

      for (final call in <(String, Map<String, Object?>)>[
        ('device_tap', {'x': 1, 'y': 1}),
        ('device_tap_element', {'text': 'Sign in'}),
        ('device_type', {'text': 'hello'}),
        ('device_key', {'key': 'back'}),
        ('device_launch_app', {'appId': 'com.example.app'}),
        ('device_terminate_app', {'appId': 'com.example.app'}),
      ]) {
        final refused = await callAs('s2', call.$1, call.$2);
        expect(
          refused.isError,
          isTrue,
          reason: '${call.$1} was allowed through while s1 was driving',
        );
        expect(refused.text, contains('Fix the login flow'));
      }
    });

    test('reading the device is never blocked', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});

      for (final name in <String>[
        'device_ui_dump',
        'device_find_elements',
        'device_screenshot',
        'device_logcat',
      ]) {
        final read = await callAs(
          's2',
          name,
          name == 'device_find_elements' ? {'text': 'Sign in'} : const {},
        );
        expect(
          read.isError,
          isFalse,
          reason: '$name was blocked: ${read.text}',
        );
      }
    });

    test('an unattributed caller respects the claim', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});

      // The launcher's own token, which names no session. There must be no
      // side door around a holder.
      final refused = await callAs(null, 'device_tap', {'x': 1, 'y': 1});
      expect(refused.isError, isTrue);
      expect(refused.text, contains('Fix the login flow'));
    });

    test('the holder keeps driving without re-asking', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      clock.advance(const Duration(seconds: 30));
      final again = await callAs('s1', 'device_type', {'text': 'hello'});
      expect(again.isError, isFalse, reason: again.text);
    });
  });

  group('a holder that goes away', () {
    test('a session that ended does not keep the device', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      SessionDao(db).updateStatus('s1', SessionStatus.completed);

      final second = await callAs('s2', 'device_tap', {'x': 100, 'y': 100});
      expect(second.isError, isFalse, reason: second.text);
    });

    test('a session we merely lost sight of keeps it', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      // `unknown` is our blind spot, not an ending — see Session.isOver.
      SessionDao(db).updateStatus('s1', SessionStatus.unknown);

      final second = await callAs('s2', 'device_tap', {'x': 100, 'y': 100});
      expect(second.isError, isTrue);
      expect(second.text, contains('Fix the login flow'));
    });

    test('a claim lapses once its holder goes quiet', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      clock.advance(kDeviceClaimLapse);

      final second = await callAs('s2', 'device_tap', {'x': 100, 'y': 100});
      expect(second.isError, isFalse, reason: second.text);
    });

    test('the ending the app does see frees the device at once', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      SessionDao(db).updateStatus('s1', SessionStatus.completed);

      // The same event that retires the session's MCP token — a change to the
      // session list, not a timer. Nothing polls for this.
      container.read(sessionsRevisionProvider.notifier).bump();
      await pumpEventQueue();

      expect(
        container.read(deviceClaimsProvider).standingClaims,
        isEmpty,
        reason: 'the claim outlived the session that took it',
      );
    });
  });
}
