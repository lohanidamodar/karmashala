import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_host/src/flutter/flutter_sdk_readings.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'flutter_fixture.dart';

void main() {
  late AppDatabase database;
  late ScriptedRunner runner;
  late DateTime now;
  late ServerFlutterSdk sdk;

  final environment = ExecutionEnvironment(
    id: 'env',
    kind: EnvironmentKind.localPosix,
    name: 'This Mac',
    createdAt: DateTime.utc(2026),
  );

  setUp(() {
    database = AppDatabase.memory();
    now = DateTime.utc(2026, 9, 8, 12);
    runner = ScriptedRunner(
      (request) => CommandResult(
        exitCode: 0,
        stdout: request.executable.startsWith('/opt/')
            ? 'Flutter 3.40.0\n'
            : '/usr/local/bin/flutter\nFlutter 3.38.5\n',
        stderr: '',
      ),
      environmentId: 'env',
    );
    sdk = ServerFlutterSdk(
      database: database,
      runners: ScriptedRunners(runner),
      clock: () => now,
    );
  });
  tearDown(() => database.close());

  void handSet(String? path) => database.writeMetadata(
    'settings.v1',
    jsonEncode({
      'flutterSdkPaths': {'env': ?path},
    }),
  );

  test('nothing has been looked at until somebody asks', () {
    expect(sdk.cached('env'), isNull);
  });

  test('a fresh reading is reused rather than re-measured', () async {
    await sdk.readFor(environment);
    final asked = runner.requests.length;
    await sdk.readFor(environment);
    expect(runner.requests, hasLength(asked));
  });

  test('a reading that has aged out is taken again', () async {
    await sdk.readFor(environment);
    final asked = runner.requests.length;
    now = now.add(const Duration(hours: 13));
    await sdk.readFor(environment);
    expect(runner.requests.length, greaterThan(asked));
  });

  test('force looks again however fresh; forget makes it measure', () async {
    await sdk.readFor(environment);
    final asked = runner.requests.length;
    await sdk.readFor(environment, force: true);
    expect(runner.requests.length, greaterThan(asked));
    sdk.forget('env');
    expect(sdk.cached('env'), isNull);
  });

  test('a hand-set path in settings.v1 is what the next reading measures, '
      'and changing it drops the fresh reading', () async {
    final onPath = await sdk.readFor(environment);
    expect(onPath.executable, '/usr/local/bin/flutter');
    handSet('/opt/flutter/bin/flutter');
    final named = await sdk.readFor(environment);
    expect(named.executable, '/opt/flutter/bin/flutter');
    handSet(null);
    final back = await sdk.readFor(environment);
    expect(back.executable, '/usr/local/bin/flutter');
  });

  test('an unreadable settings value is no hand-set path', () {
    database.writeMetadata('settings.v1', '{not json');
    expect(sdk.handSetFor('env'), isNull);
  });
}
