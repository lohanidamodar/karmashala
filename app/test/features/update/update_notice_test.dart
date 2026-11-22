import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/update/application/github_update_controller.dart';
import 'package:karmashala/src/features/update/domain/github_release.dart';
import 'package:karmashala/src/features/update/domain/install_kind.dart';
import 'package:karmashala/src/features/update/domain/update_status.dart';
import 'package:karmashala/src/features/update/presentation/update_about_rows.dart';
import 'package:karmashala/src/features/update/presentation/update_notice.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_data_server.dart';
import 'update_fakes.dart';

/// Stands in for the controller: the state is set, and every intent is
/// counted rather than carried out.
class _FakeUpdates extends GitHubUpdateController {
  _FakeUpdates(this._initial);

  final GitHubUpdateState _initial;
  int starts = 0;
  int checks = 0;
  int updates = 0;
  int installs = 0;

  @override
  GitHubUpdateState build() => _initial;

  @override
  Future<void> start() async => starts++;

  @override
  Future<void> check({bool manual = false}) async => checks++;

  @override
  Future<void> update() async => updates++;

  @override
  Future<void> install() async => installs++;
}

final _release = GitHubRelease.fromJson(
  releaseJson(
    tag: 'v1.35.0',
    body: '## Fixed\n- A long line of release notes that wraps on a phone.',
    assets: [assetJson('Karmashala-Setup-1.35.0.exe', 10)],
  ),
)!;

final _installer = UpdatePlan(
  UpdateMethod.runInstaller,
  asset: _release.assets.single,
);

const _phone = Size(360, 780);
const _desktop = Size(1440, 900);

void main() {
  late _FakeUpdates fake;

  Future<void> pump(
    WidgetTester tester,
    GitHubUpdateState state, {
    required Size size,
    required Widget Function() body,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    fake = _FakeUpdates(state);
    final server = FakeDataServer();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await server.override(),
          githubUpdateProvider.overrideWith(() => fake),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Scaffold(body: body()),
        ),
      ),
    );
    await tester.pump();
  }

  Widget notice() =>
      const GitHubUpdateNotice(child: Center(child: Text('the shell')));

  final states = <String, GitHubUpdateState>{
    'available': GitHubUpdateState(
      kind: InstallKind.windowsInstaller,
      status: UpdateAvailable(_release, _installer),
    ),
    'downloading': GitHubUpdateState(
      kind: InstallKind.windowsInstaller,
      status: UpdateDownloading(_release, _installer, received: 4, total: 10),
    ),
    'ready': GitHubUpdateState(
      kind: InstallKind.windowsInstaller,
      status: UpdateReady(_release, _installer, '/tmp/setup.exe'),
    ),
    'failed': GitHubUpdateState(
      kind: InstallKind.windowsInstaller,
      status: UpdateFailed(
        "The update did not finish: the download's checksum did not match "
        "the release's, so it was deleted",
        release: _release,
        plan: _installer,
      ),
    ),
  };

  for (final size in [_phone, _desktop]) {
    final width = size.width.round();
    group('at $width px and text 1.6', () {
      states.forEach((name, state) {
        testWidgets('the notice fits when $name', (tester) async {
          await pump(tester, state, size: size, body: notice);
          expect(find.byKey(const ValueKey('update_notice')), findsOneWidget);
          expect(find.text('the shell'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });

        testWidgets('the About rows fit when $name', (tester) async {
          await pump(
            tester,
            state,
            size: size,
            body: () => const SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: UpdateAboutRows(),
              ),
            ),
          );
          expect(
            find.byKey(const ValueKey('about_update_status')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        });
      });
    });
  }

  testWidgets(
    'the notice starts the checks and its buttons ask the controller',
    (tester) async {
      await pump(tester, states['available']!, size: _phone, body: notice);
      expect(fake.starts, 1);
      expect(find.text('Karmashala 1.35.0 is available'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('update_notice_update')));
      expect(fake.updates, 1);
    },
  );

  testWidgets("What's new shows the release notes", (tester) async {
    await pump(tester, states['available']!, size: _desktop, body: notice);
    await tester.tap(find.byKey(const ValueKey('update_notice_whats_new')));
    await tester.pumpAndSettle();
    expect(find.text("What's new in Karmashala 1.35.0"), findsOneWidget);
    expect(find.textContaining('A long line of release notes'), findsOneWidget);
  });

  testWidgets('Later hides the notice', (tester) async {
    await pump(tester, states['available']!, size: _desktop, body: notice);
    await tester.tap(find.byKey(const ValueKey('update_notice_later')));
    await tester.pump();
    expect(find.byKey(const ValueKey('update_notice')), findsNothing);
    expect(find.text('the shell'), findsOneWidget);
  });

  testWidgets('Skip hides it and remembers the version', (tester) async {
    await pump(tester, states['available']!, size: _desktop, body: notice);
    await tester.tap(find.byKey(const ValueKey('update_notice_skip')));
    await tester.pump();
    expect(find.byKey(const ValueKey('update_notice')), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.text('the shell')),
    );
    expect(
      container.read(settingsControllerProvider).skippedUpdateVersion,
      'v1.35.0',
    );
  });

  testWidgets('Install asks first, and installs only on yes', (tester) async {
    await pump(tester, states['ready']!, size: _desktop, body: notice);
    await tester.tap(find.byKey(const ValueKey('update_notice_install')));
    await tester.pumpAndSettle();
    expect(find.text('Update Karmashala?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fake.installs, 0);
    await tester.tap(find.byKey(const ValueKey('update_notice_install')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update and restart'));
    await tester.pumpAndSettle();
    expect(fake.installs, 1);
  });

  testWidgets('no notice and no About rows for a Play install', (tester) async {
    await pump(
      tester,
      const GitHubUpdateState(kind: InstallKind.androidPlay),
      size: _phone,
      body: () => const Column(
        children: [
          UpdateAboutRows(),
          Expanded(child: GitHubUpdateNotice(child: Text('the shell'))),
        ],
      ),
    );
    expect(find.byKey(const ValueKey('update_notice')), findsNothing);
    expect(find.byKey(const ValueKey('about_updates_row')), findsNothing);
  });

  testWidgets('Check for updates asks for a manual check', (tester) async {
    await pump(
      tester,
      const GitHubUpdateState(
        kind: InstallKind.windowsPortable,
        status: UpdateIdle(),
      ),
      size: _desktop,
      body: () => const SingleChildScrollView(child: UpdateAboutRows()),
    );
    await tester.tap(find.byKey(const ValueKey('about_check_updates')));
    expect(fake.checks, 1);
  });
}
