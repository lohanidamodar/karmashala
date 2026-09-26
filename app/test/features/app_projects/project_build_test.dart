import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/app_projects/application/project_build_loop.dart';
import 'package:karmashala/src/features/app_projects/application/project_build_tools.dart';
import 'package:karmashala_flutter_apps/projects.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

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

const String _flutterPubspec = '''
name: demo
dependencies:
  flutter:
    sdk: flutter
flutter:
  uses-material-design: true
''';

void main() {
  late AppDatabase db;
  late FakeCommandRunner runner;
  late ProviderContainer container;

  /// A distribution holding one native Android project at `/home/me/android`,
  /// wrapper and all — the ordinary case, so a test can change one thing.
  CommandResult native(CommandRequest request) {
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
        _ => const CommandResult(exitCode: 1, stdout: '', stderr: ''),
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
        _ => const CommandResult(exitCode: 1, stdout: '', stderr: ''),
      };
    }
    return const CommandResult(exitCode: 1, stdout: '', stderr: '');
  }

  Future<void> make({CommandResult Function(CommandRequest)? responder}) async {
    db = AppDatabase.memory();
    final server = FakeDataServer();
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(
      repository(
        id: 'android',
        environmentId: 'wsl:Ubuntu',
        path: '/home/me/android',
      ),
    );
    AgentInstallationDao(db).insert(agentInstallation());
    runner = FakeCommandRunner(
      environmentId: 'wsl:Ubuntu',
      responder: responder ?? native,
    );
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        await server.override(),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
      ],
    );
  }

  setUp(make);
  tearDown(() {
    container.dispose();
    db.close();
  });

  ProjectBuildController builds() =>
      container.read(projectBuildProvider.notifier);

  group('the preflight, before anything is spawned', () {
    test(
      "an environment nothing records is refused in the resolver's words",
      () async {
        final ready = await builds().readiness(
          const EnvironmentPath(environmentId: 'gone', path: '/x'),
          ProjectTarget.android,
        );
        expect(
          ready.preflight.problem,
          ProjectBuildProblem.environmentUnresolved,
        );
        expect(ready.preflight.reason, contains('Unknown environment: gone'));
        // Nothing was run on the way to that answer.
        expect(runner.requests, isEmpty);
      },
    );

    test(
      'a Flutter host module is refused by name, not as "no project"',
      () async {
        await make(
          responder: (request) =>
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
        expect(ready.preflight.reason, contains('one directory up'));
      },
    );

    test(
      'no wrapper in the project refuses rather than reaching for gradle',
      () async {
        await make(
          responder: (request) =>
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
        expect(ready.preflight.reason, contains('gradlew'));
        expect(ready.preflight.reason, contains('will not fall back to a'));
      },
    );

    test(
      'a detected iOS project refuses to build, in the descriptor\'s words',
      () async {
        await make(
          responder: (request) => request.executable == 'ls'
              ? switch (request.arguments.last) {
                  '/home/me/android' => const CommandResult(
                    exitCode: 0,
                    stdout: 'MyApp.xcodeproj\nMyApp.xcworkspace\nMyApp\n',
                    stderr: '',
                  ),
                  '/home/me/android/MyApp.xcodeproj/xcshareddata/xcschemes' =>
                    const CommandResult(
                      exitCode: 0,
                      stdout: 'MyApp.xcscheme\n',
                      stderr: '',
                    ),
                  _ => const CommandResult(exitCode: 1, stdout: '', stderr: ''),
                }
              : const CommandResult(exitCode: 1, stdout: '', stderr: ''),
        );
        final scanned = await builds().scan(_project);
        expect(scanned.project!.kind, ProjectKind.nativeIos);
        expect(scanned.project!.iosScheme, 'MyApp');

        final ready = await builds().readiness(_project, ProjectTarget.ios);
        expect(ready.preflight.problem, ProjectBuildProblem.targetUnchecked);
        expect(ready.preflight.reason, contains('needs a Mac'));
        expect(
          ready.preflight.reason,
          contains('release-build.yml has no macOS job'),
        );
        expect(ready.argv, isEmpty);
        // Detection worked; only the build refused.
        expect(ready.project, isNotNull);
      },
    );

    test('an Android project has no iOS target, and says so', () async {
      final ready = await builds().readiness(_project, ProjectTarget.ios);
      expect(ready.preflight.problem, ProjectBuildProblem.targetUnknown);
      expect(ready.preflight.reason, contains('Android'));
    });
  });

  group('the build itself', () {
    test('opens a visible pane on the project\'s own wrapper', () async {
      final outcome = await builds().start(_project, ProjectTarget.android);
      expect(outcome.preflight.isClear, isTrue);
      final run = outcome.run!;
      expect(run.kind, ProjectKind.nativeAndroid);
      expect(run.command, <String>['./gradlew', ':app:assembleDebug']);
      expect(run.module, ':app');
      expect(run.artifactDirectory, 'app/build/outputs/apk/debug');

      // And it reaches the *distribution*, not this host — the §17 half.
      final instance = container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(run.paneId)!;
      final launch = instance.agentLaunch!;
      expect(launch.executable, './gradlew');
      expect(launch.arguments, <String>[':app:assembleDebug']);
      expect(launch.workingDirectory, '/home/me/android');
      expect(launch.wslDistribution, 'Ubuntu');
      expect(builds().livenessOf(run.paneId), ProjectBuildLiveness.running);
    });

    test(
      'a second build for the same target is refused, naming the pane',
      () async {
        final first = await builds().start(_project, ProjectTarget.android);
        final second = await builds().start(_project, ProjectTarget.android);
        expect(second.run, isNull);
        expect(second.preflight.problem, ProjectBuildProblem.alreadyRunning);
        expect(second.preflight.reason, contains(first.run!.paneId));
      },
    );

    test('the artifact and the id come off the build\'s own record', () async {
      final run = (await builds().start(_project, ProjectTarget.android)).run!;
      final artifact = await builds().artifactOf(run);
      expect(
        artifact.path,
        '/home/me/android/app/build/outputs/apk/debug/app-debug.apk',
      );
      expect(artifact.applicationId, 'com.popupbits.nativeprobe');
      expect(artifact.note, contains('output-metadata.json'));
    });

    test(
      'nothing built yet is "not there", never a path that does not exist',
      () async {
        await make(
          responder: (request) =>
              request.executable == 'ls' &&
                  request.arguments.last.contains('outputs')
              ? const CommandResult(exitCode: 1, stdout: '', stderr: '')
              : native(request),
        );
        final run = (await builds().start(
          _project,
          ProjectTarget.android,
        )).run!;
        final artifact = await builds().artifactOf(run);
        expect(artifact.path, isNull);
        expect(artifact.note, contains('not there'));
      },
    );
  });

  group('the tool', () {
    test('detect names the kind, the module and what can be built', () async {
      final answer =
          await ProjectBuildTools(container).call('project_build', {
                'action': 'detect',
                'checkoutId': 'android',
              })
              as Map<String, Object?>;
      expect(answer['detected'], isTrue);
      expect(answer['kind'], 'nativeAndroid');
      expect(answer['androidModule'], ':app');
      final descriptor = answer['descriptor'] as Map<String, Object?>;
      expect(descriptor['kind'], 'nativeAndroid');
    });

    test(
      'status hands the caller the two device tools, and does neither',
      () async {
        await ProjectBuildTools(
          container,
        ).call('project_build', {'action': 'build', 'checkoutId': 'android'});
        final answer =
            await ProjectBuildTools(container).call('project_build', {
                  'action': 'status',
                  'checkoutId': 'android',
                })
                as Map<String, Object?>;
        final runs = answer['runs']! as List<Object?>;
        final first = runs.single as Map<String, Object?>;
        final next = first['nextStep']! as String;
        expect(next, contains('device_install_app'));
        expect(next, contains('app-debug.apk'));
        expect(next, contains('device_launch_app'));
        expect(next, contains('com.popupbits.nativeprobe'));
        // There is no install or launch in this tool at all.
        expect(
          projectBuildToolSchemas.single['inputSchema'].toString(),
          isNot(contains('install')),
        );
      },
    );
  });

  group('the seam', () {
    test(
      'a Flutter checkout builds through the same tool and the Flutter SDK',
      () async {
        await make(
          responder: (request) {
            if (request.arguments.contains('exit 0')) {
              return const CommandResult(exitCode: 0, stdout: '', stderr: '');
            }
            if (request.arguments.contains('command -v flutter')) {
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
            if (request.executable == 'cat' &&
                request.arguments.last == '/home/me/android/pubspec.yaml') {
              return const CommandResult(
                exitCode: 0,
                stdout: _flutterPubspec,
                stderr: '',
              );
            }
            return native(request);
          },
        );
        final outcome = await builds().start(_project, ProjectTarget.android);
        expect(
          outcome.preflight.isClear,
          isTrue,
          reason: outcome.preflight.reason,
        );
        final run = outcome.run!;
        expect(run.kind, ProjectKind.flutter);
        // The same tool, a different descriptor — which is the whole point of
        // the boundary. Nothing here knows the word "Flutter" or "Gradle".
        expect(run.command, <String>[
          '/home/me/flutter/bin/flutter',
          'build',
          'apk',
          '--debug',
        ]);
        expect(run.artifactDirectory, 'build/app/outputs/flutter-apk');
      },
    );
  });
}
