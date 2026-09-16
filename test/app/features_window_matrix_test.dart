import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/browser/application/browser_providers.dart';
import 'package:karmashala/src/features/browser/presentation/browser_pane.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_app_providers.dart';
import 'package:karmashala/src/features/flutter_apps/presentation/flutter_app_pane.dart';
import 'package:karmashala/src/features/github/application/github_providers.dart';
import 'package:karmashala/src/features/github/presentation/github_view.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/todos/presentation/todos_view.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/theme.dart';

import '../features/browser/fake_browser.dart';
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
      final fake = FakeBrowser();
      await expectSurvivesWindowMatrix(
        tester,
        build: () => ProviderScope(
          overrides: [browserServiceProvider.overrideWithValue(fake.service)],
          child: sidePanel(const BrowserPane()),
        ),
        because: 'the not-connected explanation is taller than a 240px panel',
      );
    });

    testWidgets('BrowserPane, with how attaching works unfolded', (
      tester,
    ) async {
      final fake = FakeBrowser();
      await expectSurvivesWindowMatrix(
        tester,
        build: () => ProviderScope(
          overrides: [browserServiceProvider.overrideWithValue(fake.service)],
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
      final temp = Directory.systemTemp.createTempSync('karmashala-side-panel');
      addTearDown(() => temp.deleteSync(recursive: true));
      await expectSurvivesWindowMatrix(
        tester,
        build: () => ProviderScope(
          overrides: [
            clockProvider.overrideWithValue(
              FixedClock(DateTime.utc(2026, 9, 8)),
            ),
            flutterAppDiscoveryDirectoryProvider.overrideWith(
              (ref) async => VmServiceUriDirectory(temp),
            ),
            dtdPidFilesProvider.overrideWithValue(const DtdPidFiles(null)),
            adbServiceProvider.overrideWithValue(null),
            devicesProvider.overrideWith((ref) async => const []),
            vmServiceConnectorProvider.overrideWithValue(
              (uri) async => throw StateError('nothing listens'),
            ),
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

    testWidgets('TodosView with no todos', (tester) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () {
          final db = AppDatabase.memory();
          addTearDown(db.close);
          ExecutionEnvironmentDao(db).upsert(windowsEnv());
          ProjectDao(db).insert(project());
          final container = ProviderContainer(
            overrides: [databaseProvider.overrideWithValue(db)],
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
