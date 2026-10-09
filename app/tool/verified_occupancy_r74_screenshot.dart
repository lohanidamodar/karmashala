// Renders round 74: a stale verdict on the dashboard card and on the session
// status line beside "shared with 1", and the New session dialog's warning
// that others are working in the checkout — at 390 and 1440 px.
// Under tool/ so `flutter test` never picks it up; run it explicitly from
// app/:
//
//   flutter test tool/verified_occupancy_r74_screenshot.dart
//
// Images land in build/verified-occupancy-r74/.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart'
    show selectedRepositoryIdProvider;
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart'
    show sessionDeliveryProvider;
import 'package:karmashala/src/features/sessions/presentation/delivery_strip.dart'
    show DeliveryStateLine;
import 'package:karmashala/src/features/sessions/presentation/new_session_dialog.dart';
import 'package:karmashala_session/delivery.dart' show SessionDelivery;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart' show UiDensity;
import 'package:karmashala_verification/verification.dart';

import '../test/features/overview/mission_fixture.dart';
import '../test/features/terminal/fake_instance.dart';
import '../test/support/fake_command_runner.dart';
import '../test/support/fake_data_server.dart';
import '../test/support/fixtures.dart';
import '../test/support/test_machine.dart';

const _outDir = 'build/verified-occupancy-r74';
const _head = 'dddddddddddddddddddddddddddddddddddddddd';
const _app = EnvironmentPath(
  environmentId: 'windows',
  path: r'C:\src\demo\app',
);

Future<void> _loadBundledFonts() async {
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(family['family']! as String);
    for (final font
        in (family['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
}

Future<void> _save(WidgetTester tester, GlobalKey key, String name) =>
    tester.runAsync(() async {
      final render =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });

void main() {
  setUpAll(_loadBundledFonts);

  for (final (width, phone) in const [(1440.0, false), (390.0, true)]) {
    final size = Size(width, phone ? 844 : 900);
    final tag = '${width.round()}';

    // Below the wide layout the dashboard lists one-line rows, which carry no
    // verdict; at 390 px the stale result is the status line's.
    testWidgets('a stale check on the dashboard card $tag', skip: phone, (
      tester,
    ) async {
      final key = GlobalKey();
      await pumpMission(
        tester,
        fixture: MissionFixture.full(
          verificationRuns: [
            VerificationRun(
              id: 'vr-r30',
              title: 'Project checks',
              target: const VerificationTarget.change(),
              startedAt: MissionFixture.now,
              finishedAt: MissionFixture.now,
              verdict: VerificationVerdict.pass,
              artifactDirectory: '/art/vr-r30',
              sessionId: 'ks-r30',
              producedBySessionId: 'karmashala',
              identity: const CodeIdentity(
                environmentId: 'windows',
                path: '/src/ks-r30',
                head: _head,
                tree: '',
                dirty: {},
              ),
            ),
          ],
          codeFreshness: {
            _head: const CodeFreshness.stale(
              'Uncommitted files changed since this ran.',
              filesChanged: 3,
            ),
          },
        ),
        prefsDir: Directory.systemTemp.createTempSync('ks-r74-shot'),
        size: size,
        phone: phone,
        boundary: key,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('overview-verdict:ks-r30')),
        200,
        scrollable: hybridList,
      );
      await settleMission(tester);
      await _save(tester, key, 'dashboard-stale-$tag');
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });

    group('with sessions in the checkout $tag', () {
      late TestMachine db;
      late FakeDataServer server;

      setUp(() async {
        db = TestMachine();
        server = FakeDataServer()..runsOn(db);
        server.environmentRows.upsert(windowsEnv());
        server.projectRows.insert(project(id: 'p1'));
        server.repositoryRows.insert(
          repository(id: 'r1', projectId: 'p1', name: 'app'),
        );
        server.installationRows
          ..insert(agentInstallation())
          ..insert(
            agentInstallation(
              id: 'codex',
              agentId: AgentIds.codex,
              path: r'C:\Users\me\.bin\codex.exe',
            ),
          );
        for (final (id, title, installation, status) in const [
          ('s1', 'Fix the login retry', 'a1', SessionStatus.running),
          ('s2', 'Tidy the parser', 'codex', SessionStatus.idle),
        ]) {
          db.server.sessionRows.insert(
            Session(
              id: id,
              repositoryId: 'r1',
              agentInstallationId: installation,
              title: title,
              useWorktree: false,
              workingDirectory: _app,
              status: status,
              createdAt: testTime,
            ),
          );
        }
        db.server.verificationRows
          ..insertRun(
            VerificationRun(
              id: 'v1',
              title: 'Project checks',
              target: const VerificationTarget.change(),
              startedAt: testTime,
              artifactDirectory: 'C:/art/v1',
              sessionId: 's1',
              producedBySessionId: 'karmashala',
              identity: const CodeIdentity(
                environmentId: 'windows',
                path: r'C:\src\demo\app',
                head: _head,
                tree: '',
                dirty: {},
              ),
            ),
          )
          ..finishRun(
            'v1',
            finishedAt: testTime.add(const Duration(minutes: 2)),
            verdict: VerificationVerdict.pass,
          );
        server.gitWork.codeFreshness[_head] = const CodeFreshness.stale(
          'Uncommitted files changed since this ran.',
          filesChanged: 3,
        );
      });

      Future<ProviderContainer> container() async {
        final data = await server.connect();
        final container = ProviderContainer(
          overrides: [
            dataClientProvider.overrideWithValue(data),
            agentUsageProvider.overrideWith(
              (ref, installation) => const AsyncLoading<AgentUsage>(),
            ),
            ...fakeTerminalOverrides(machine: db),
            commandRunnerFactoryProvider.overrideWithValue(
              FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
            ),
            hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
            sessionDeliveryProvider.overrideWith(
              (ref, _) async =>
                  const SessionDelivery(branch: 'fix/login', dirtyFiles: 3),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(selectedRepositoryIdProvider.notifier).select('r1');
        return container;
      }

      Future<GlobalKey> pump(
        WidgetTester tester,
        ProviderContainer container,
        Widget home,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.dark().copyWith(
                platform: phone
                    ? TargetPlatform.android
                    : TargetPlatform.windows,
              ),
              builder: (context, child) => RepaintBoundary(
                key: key,
                child: UiDensity.wrap(context, child!),
              ),
              home: Scaffold(body: home),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return key;
      }

      testWidgets('the status line, stale and shared', (tester) async {
        final key = await pump(
          tester,
          await container(),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.topLeft,
              child: DeliveryStateLine(sessionId: 's1'),
            ),
          ),
        );
        await _save(tester, key, 'status-line-$tag');
        expect(tester.takeException(), isNull);
      });

      testWidgets('the New session warning', (tester) async {
        final key = await pump(
          tester,
          await container(),
          Builder(
            builder: (context) => TextButton(
              onPressed: () => NewSessionDialog.show(context),
              child: const Text('open'),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final warning = find.byKey(
          const ValueKey('checkout-occupancy-warning'),
        );
        await tester.ensureVisible(warning);
        await tester.pumpAndSettle();
        await _save(tester, key, 'new-session-warning-$tag');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump(const Duration(milliseconds: 1));
      });
    });
  }
}
