import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/browser/presentation/browser_pane.dart';
import 'package:karmashala/src/features/flutter_apps/presentation/flutter_app_pane.dart';
import 'package:karmashala/src/features/github/application/github_providers.dart';
import 'package:karmashala/src/features/github/presentation/github_view.dart';
import 'package:karmashala/src/features/todos/presentation/todos_view.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_devices/ports.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/widgets.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_ui/theme.dart';

import '../support/fake_command_runner.dart';
import '../support/fake_data_server.dart';
import '../support/fakes.dart';
import '../support/fixtures.dart';
import '../support/window_matrix.dart';

/// Side panel at the minimum window: 240 wide, window height less title bar 30,
/// status bar 22, panel header 30.
Widget sidePanel(Widget surface) => MaterialApp(
  theme: AppTheme.light(),
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    body: LayoutBuilder(
      builder: (context, c) => Align(
        alignment: Alignment.topRight,
        child: SizedBox(
          width: 240,
          height: c.maxHeight - 82,
          child: Material(child: surface),
        ),
      ),
    ),
  ),
);

void main() {
  group('side panels at their real size', () {
    testWidgets('BrowserPane, not connected', (tester) async {
      final data = await FakeDataServer().override();
      await expectSurvivesWindowMatrix(
        tester,
        build: () => ProviderScope(
          overrides: [data],
          child: sidePanel(const BrowserPane()),
        ),
        because: 'the not-connected explanation is taller than a 240px panel',
      );
    });

    testWidgets('BrowserPane, with how attaching works unfolded', (
      tester,
    ) async {
      final data = await FakeDataServer().override();
      await expectSurvivesWindowMatrix(
        tester,
        build: () => ProviderScope(
          overrides: [data],
          child: sidePanel(const BrowserPane()),
        ),
        warmUp: (tester) async {
          await tester.tap(find.text('How attaching works'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Attach · 9222'));
        },
        because: 'unfolded, the explanation must scroll rather than clip',
      );
    });

    testWidgets('FlutterAppPane, nothing attached, attaching by address', (
      tester,
    ) async {
      final data = await FakeDataServer().override();
      await expectSurvivesWindowMatrix(
        tester,
        build: () => ProviderScope(
          overrides: [
            clockProvider.overrideWithValue(
              FixedClock(DateTime.utc(2026, 9, 8)),
            ),
            adbServiceProvider.overrideWithValue(null),
            devicesProvider.overrideWith((ref) async => const []),
            data,
          ],
          child: sidePanel(const FlutterAppPane()),
        ),
        warmUp: (tester) async {
          await tester.ensureVisible(find.text('Attach by address'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Attach by address'));
        },
        because: 'the address field is the way out, below a long empty state',
      );
    });

    testWidgets('FlutterAppPane, a console with search, filters and an error', (
      tester,
    ) async {
      final server = FakeDataServer();
      final data = await server.override();
      final at = DateTime.utc(2026, 9, 8);
      server.runs.setApps(
        FlutterAppRegistry(
          apps: [
            AttachedApp(
              id: '127.0.0.1:1/a=',
              uri: Uri.parse('ws://127.0.0.1:1/a=/ws'),
              discovery: AppDiscovery.uriFile,
              reachability: AppReachability.attached,
              observedAt: at,
              label: 'app',
            ),
          ],
          lookedAt: at,
        ),
      );
      await tester.runAsync(pumpEventQueue);
      await expectSurvivesWindowMatrix(
        tester,
        build: () => ProviderScope(
          overrides: [
            clockProvider.overrideWithValue(FixedClock(at)),
            adbServiceProvider.overrideWithValue(null),
            devicesProvider.overrideWith((ref) async => const []),
            data,
          ],
          child: sidePanel(const FlutterAppPane()),
        ),
        warmUp: (tester) async {
          await tester.pump();
          server.runs.log('127.0.0.1:1/a=', [
            for (var i = 0; i < 30; i++)
              AppLogRecord(
                source: AppLogSource.stdout,
                at: at,
                message: 'flutter: a fairly long line of output number $i',
              ),
            AppLogRecord(
              source: AppLogSource.developerLog,
              at: at,
              message: 'connected',
              loggerName: 'network.http',
            ),
            AppLogRecord(
              source: AppLogSource.flutterError,
              at: at,
              message: 'A RenderFlex overflowed by 42 pixels on the right.',
              detail: 'The relevant error-causing widget was:\n  Row',
            ),
          ]);
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'output');
          await tester.pumpAndSettle();
          await tester.testTextInput.receiveAction(TextInputAction.done);
        },
        because: 'the console toolbar must fold into 240px, at 1.3x text too',
      );
    });

    testWidgets('DeviceLogcatSection, open, with search and lines', (
      tester,
    ) async {
      const device = AndroidDevice(
        serial: 'emulator-5554',
        environmentId: 'windows',
        state: DeviceConnectionState.device,
        model: 'Pixel',
      );
      final spawned = <FakeProcessHandle>[];
      await expectSurvivesWindowMatrix(
        tester,
        build: () {
          final runner = FakeCommandRunner(
            processFactory: (_) {
              final handle = FakeProcessHandle();
              spawned.add(handle);
              return handle;
            },
          );
          return ProviderScope(
            overrides: [
              adbServiceProvider.overrideWithValue(
                AdbService(
                  runner: runner,
                  sdk: const AndroidSdk(
                    root: EnvironmentPath(
                      environmentId: 'windows',
                      path: r'C:\sdk',
                    ),
                    adb: EnvironmentPath(
                      environmentId: 'windows',
                      path: r'C:\sdk\platform-tools\adb.exe',
                    ),
                  ),
                ),
              ),
              deviceClockProvider.overrideWithValue(
                FixedClock(DateTime.utc(2026, 9, 8)),
              ),
            ],
            child: sidePanel(
              const Column(
                children: [
                  Expanded(child: SizedBox.shrink()),
                  DeviceLogcatSection(device: device),
                ],
              ),
            ),
          );
        },
        warmUp: (tester) async {
          await tester.tap(find.textContaining('Logcat — Pixel'));
          await tester.pumpAndSettle();
          for (var i = 0; i < 30; i++) {
            spawned.last.emitStdout(
              '09-08 10:15:33.123  1234  5678 ${i.isEven ? 'I' : 'E'} '
              'ActivityManager: a fairly long logcat line number $i',
            );
          }
          await tester.pump(DeviceLogcatSession.flushWindow);
          await tester.pumpAndSettle();
          await tester.enterText(
            find.descendant(
              of: find.byKey(DeviceLogcatToolbar.searchKey),
              matching: find.byType(TextField),
            ),
            'line',
          );
          await tester.pumpAndSettle();
        },
        because: 'the logcat toolbar must fold into 240px, at 1.3x text too',
      );
    });

    testWidgets('TodosView with no todos', (tester) async {
      final server = FakeDataServer();
      server.projectRows.insert(project());
      final data = await server.connect();
      await expectSurvivesWindowMatrix(
        tester,
        build: () {
          server.environmentRows.upsert(windowsEnv());
          final container = ProviderContainer(
            overrides: [dataClientProvider.overrideWithValue(data)],
          );
          addTearDown(container.dispose);
          return UncontrolledProviderScope(
            container: container,
            child: sidePanel(const TodosView()),
          );
        },
        because: '"No todos yet" sits under the composer in 240px',
      );
    });

    testWidgets('GitHubView when gh fails', (tester) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () => ProviderScope(
          overrides: [
            githubRepositoryProvider.overrideWith((ref) async => null),
            githubPullRequestsProvider.overrideWith(
              (ref) async => throw Exception('gh not authenticated'),
            ),
            githubIssuesProvider.overrideWith((ref) async => const []),
          ],
          child: sidePanel(const GitHubView()),
        ),
        because: 'an error banner and an empty list share 240px',
      );
    });
  });
}
