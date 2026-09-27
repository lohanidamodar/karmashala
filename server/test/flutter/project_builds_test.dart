import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_flutter_apps/projects.dart';
import 'package:karmashala_host/src/flutter/project_builds.dart';
import 'package:karmashala_host/src/mcp/tools/build_tool_schemas.dart';
import 'package:karmashala_host/src/mcp/tools/build_tool_set.dart';
import 'package:test/test.dart';

import 'flutter_fixture.dart';

const EnvironmentPath _project = EnvironmentPath(
  environmentId: 'wsl:Ubuntu',
  path: '/home/me/android',
);

const String _settings = '''
plugins {
    id("com.android.application") version "9.0.1" apply false
}
rootProject.name = "nativeprobe"
include(":app")
''';

const String _appModule = '''
plugins {
    id("com.android.application")
}
android {
    namespace = "com.popupbits.nativeprobe"
    defaultConfig {
        applicationId = "com.popupbits.nativeprobe"
    }
}
''';

const String _metadata = '''
{"version": 3, "applicationId": "com.popupbits.nativeprobe",
 "variantName": "debug",
 "elements": [{"outputFile": "app-debug.apk"}]}
''';

CommandResult native(CommandRequest request) {
  const missing = CommandResult(exitCode: 1, stdout: '', stderr: '');
  final argument = request.arguments.isEmpty ? '' : request.arguments.last;
  if (request.executable == 'cat') {
    return switch (argument) {
      '/home/me/android/settings.gradle.kts' => const CommandResult(
        exitCode: 0,
        stdout: _settings,
        stderr: '',
      ),
      '/home/me/android/app/build.gradle.kts' => const CommandResult(
        exitCode: 0,
        stdout: _appModule,
        stderr: '',
      ),
      '/home/me/android/app/build/outputs/apk/debug/output-metadata.json' =>
        const CommandResult(exitCode: 0, stdout: _metadata, stderr: ''),
      _ => missing,
    };
  }
  if (request.executable == 'ls') {
    return switch (argument) {
      '/home/me/android' => const CommandResult(
        exitCode: 0,
        stdout: 'app\ngradle\ngradlew\ngradlew.bat\nsettings.gradle.kts\n',
        stderr: '',
      ),
      '/home/me/android/app/build/outputs/apk/debug' => const CommandResult(
        exitCode: 0,
        stdout: 'app-debug.apk\noutput-metadata.json\n',
        stderr: '',
      ),
      _ => missing,
    };
  }
  return missing;
}

void main() {
  late FlutterFixture fixture;

  void make([CommandResult Function(CommandRequest)? responder]) {
    fixture = FlutterFixture(responder: responder ?? native);
    fixture.database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, '
      "path, created_at) VALUES ('android', 'p1', 'android', 'wsl:Ubuntu', "
      "'/home/me/android', ?);",
      [fixtureNow.toIso8601String()],
    );
  }

  Future<void> remake(CommandResult Function(CommandRequest) responder) async {
    await fixture.close();
    make(responder);
  }

  setUp(make);
  tearDown(() => fixture.close());

  ServerProjectBuilds builds() => fixture.work.builds;

  group('the preflight, before anything is spawned', () {
    test('an environment nothing records is refused in words', () async {
      final ready = await builds().readiness(
        const EnvironmentPath(environmentId: 'gone', path: '/x'),
        ProjectTarget.android,
      );
      expect(
        ready.preflight.problem,
        ProjectBuildProblem.environmentUnresolved,
      );
      expect(ready.preflight.reason, contains('gone'));
      expect(fixture.runner.requests, isEmpty);
    });

    test('an SSH checkout is refused in words', () async {
      final ready = await builds().readiness(
        const EnvironmentPath(environmentId: 'box', path: '/srv/app'),
        ProjectTarget.android,
      );
      expect(ready.preflight.reason, contains('SSH machine'));
    });

    test('a Flutter host module is refused by name', () async {
      await remake(
        (request) =>
            request.executable == 'cat' &&
                request.arguments.last.endsWith('settings.gradle.kts')
            ? const CommandResult(
                exitCode: 0,
                stdout:
                    'plugins { id("dev.flutter.flutter-plugin-loader") '
                    'version "1.0.0" }\ninclude(":app")\n',
                stderr: '',
              )
            : native(request),
      );
      final ready = await builds().readiness(_project, ProjectTarget.android);
      expect(ready.preflight.problem, ProjectBuildProblem.notAProject);
      expect(ready.preflight.reason, contains('Android half of a Flutter'));
    });

    test('no wrapper refuses rather than reaching for gradle', () async {
      await remake(
        (request) =>
            request.executable == 'ls' &&
                request.arguments.last == '/home/me/android'
            ? const CommandResult(
                exitCode: 0,
                stdout: 'app\ngradle\nsettings.gradle.kts\n',
                stderr: '',
              )
            : native(request),
      );
      final ready = await builds().readiness(_project, ProjectTarget.android);
      expect(ready.preflight.problem, ProjectBuildProblem.noWrapper);
      expect(ready.preflight.reason, contains('will not fall back to a'));
    });

    test('an Android project has no iOS target, and says so', () async {
      final ready = await builds().readiness(_project, ProjectTarget.ios);
      expect(ready.preflight.problem, ProjectBuildProblem.targetUnknown);
      expect(ready.preflight.reason, contains('Android'));
    });
  });

  group('the build itself', () {
    test('runs the project\'s own wrapper as a hosted run', () async {
      final outcome = await builds().start(_project, ProjectTarget.android);
      expect(outcome.preflight.isClear, isTrue);
      final run = outcome.run!;
      expect(run.kind, ProjectKind.nativeAndroid);
      expect(run.command, ['./gradlew', ':app:assembleDebug']);
      expect(run.artifactDirectory, 'app/build/outputs/apk/debug');
      final argv = fixture.pty.started.single.argv;
      expect(argv, containsAllInOrder(['-d', 'Ubuntu', '--cd']));
      expect(argv.sublist(argv.length - 2), [
        './gradlew',
        ':app:assembleDebug',
      ]);
      expect(builds().livenessOf(run.paneId), ProjectBuildLiveness.running);
      final told = fixture.told.whereType<HostedRunChanged>().single.run;
      expect(told.family, HostedRunFamily.build);
      expect(told.paneId, run.paneId);
    });

    test('a second build for the same target is refused by name', () async {
      final first = await builds().start(_project, ProjectTarget.android);
      final second = await builds().start(_project, ProjectTarget.android);
      expect(second.run, isNull);
      expect(second.preflight.problem, ProjectBuildProblem.alreadyRunning);
      expect(second.preflight.reason, contains(first.run!.paneId));
    });

    test('the artifact and the id come off the build\'s own record', () async {
      final run = (await builds().start(_project, ProjectTarget.android)).run!;
      final artifact = await builds().artifactOf(run);
      expect(
        artifact.path,
        '/home/me/android/app/build/outputs/apk/debug/app-debug.apk',
      );
      expect(artifact.applicationId, 'com.popupbits.nativeprobe');
    });

    test('stop ends the build and keeps its record', () async {
      final run = (await builds().start(_project, ProjectTarget.android)).run!;
      final stopped = await builds().stop(run.paneId);
      expect(stopped!.endedAt, isNotNull);
      await settle();
      expect(builds().livenessOf(run.paneId), ProjectBuildLiveness.finished);
    });
  });

  group('the tool', () {
    BuildToolSet tools() => BuildToolSet(
      builds: fixture.work.builds,
      rows: CheckoutRows(fixture.database),
    );

    test('detect names the kind and the module', () async {
      final answer =
          await tools().call('project_build', {
                'action': 'detect',
                'checkoutId': 'android',
              }, null)
              as Map<String, Object?>;
      expect(answer['detected'], isTrue);
      expect(answer['kind'], 'nativeAndroid');
      expect(answer['androidModule'], ':app');
    });

    test('status hands over the two device tools, and does neither', () async {
      await tools().call('project_build', {
        'action': 'build',
        'checkoutId': 'android',
      }, null);
      final answer =
          await tools().call('project_build', {'action': 'status'}, null)
              as Map<String, Object?>;
      final first = (answer['runs']! as List).single as Map<String, Object?>;
      final next = first['nextStep']! as String;
      expect(next, contains('device_install_app'));
      expect(next, contains('com.popupbits.nativeprobe'));
      expect(
        projectBuildToolSchemas.single['inputSchema'].toString(),
        isNot(contains('install')),
      );
    });

    test('a checkout nobody knows is refused', () async {
      await expectLater(
        tools().call('project_build', {
          'action': 'detect',
          'checkoutId': 'nope',
        }, null),
        throwsA(isA<StateError>()),
      );
    });

    test('stop without a pane id is a caller mistake', () async {
      await expectLater(
        tools().call('project_build', {'action': 'stop'}, null),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
