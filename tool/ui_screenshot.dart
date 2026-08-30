// A throwaway harness: renders the real shell into PNGs so a layout and colour
// change can be *looked at*. Lives under tool/ so `flutter test` never picks it
// up; run it explicitly:
//
//   flutter test tool/ui_screenshot.dart
//
// Images land in build/ui-screenshots/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chitragupta/src/app/chitragupta_app.dart';
import 'package:chitragupta/src/app/shell/side_panel_state.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:chitragupta/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/projects/application/projects_controller.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_status_providers.dart';
import 'package:chitragupta/src/features/git/application/changes_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_ui_providers.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/application/system_terminal_providers.dart';
import 'package:chitragupta/src/features/terminal/data/system_terminal_service.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/features/terminal/fake_instance.dart';
import '../test/support/fake_command_runner.dart';
import '../test/support/fakes.dart';
import '../test/support/fixtures.dart';

const _outDir = 'build/ui-screenshots';

const _fontDir = r'C:\Users\dlohani\flutter\bin\cache\artifacts\material_fonts';

/// flutter_test draws every glyph as a filled box unless real fonts are loaded,
/// which makes a screenshot useless for judging type and density.
Future<void> _loadFonts() async {
  Future<void> load(String family, Map<String, String> faces) async {
    final loader = FontLoader(family);
    for (final entry in faces.entries) {
      loader.addFont(
        File(entry.value).readAsBytes().then(ByteData.sublistView),
      );
    }
    await loader.load();
  }

  await load('Roboto', {
    'regular': '$_fontDir/roboto-regular.ttf',
    'medium': '$_fontDir/roboto-medium.ttf',
    'bold': '$_fontDir/roboto-bold.ttf',
  });
  await load('MaterialIcons', {
    'regular': '$_fontDir/materialicons-regular.otf',
  });
  await load('monospace', {'regular': r'C:\Windows\Fonts\consola.ttf'});
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUpAll(_loadFonts);

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db)
      ..insert(
        project(id: 'p1', name: 'chitragupta', path: r'C:\src\chitragupta'),
      )
      ..insert(
        project(id: 'p2', name: 'meronepali', path: r'C:\src\meronepali'),
      );
    RepositoryDao(db)
      ..insert(repository(id: 'r1', projectId: 'p1', name: 'chitragupta-app'))
      ..insert(repository(id: 'r2', projectId: 'p1', name: 'mcp_bridge'))
      ..insert(repository(id: 'r3', projectId: 'p2', name: 'app'));
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db)
      ..insert(
        session(
          id: 's1',
          title: 'Overhaul the desktop UI',
          status: SessionStatus.running,
        ),
      )
      ..insert(
        session(
          id: 's2',
          title: 'Fix the scrollback restore',
          status: SessionStatus.completed,
        ),
      );

    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        sessionTranscriptProvider.overrideWith((ref) => Stream.value(const [])),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeCode,
              sessionId: id,
              status: id == 's1'
                  ? AgentActivityStatus.working
                  : AgentActivityStatus.idle,
              observedAt: testTime,
              source: AgentStatusSource.hook,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  Future<void> shoot(
    WidgetTester tester, {
    required String name,
    required Size size,
    required Brightness brightness,
    SidePanelSurface? panel = SidePanelSurface.changes,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    // A bounded settle everywhere: the transcript surface holds a progress
    // indicator that never stops animating, so pumpAndSettle would time out.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    final key = GlobalKey();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(key: key, child: const ChitraguptaApp()),
      ),
    );
    await settle(tester);

    // Two terminals with something in them; a real screenshot of an empty
    // terminal proves nothing about how the chrome sits beside content.
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    if (container.read(terminalSessionsControllerProvider).tabs.length < 2) {
      terminals.openTab(TerminalProfile.powerShell);
      await settle(tester);
    }
    for (final tab in container.read(terminalSessionsControllerProvider).tabs) {
      final instance = terminals.instanceFor(tab.focusedPaneId);
      instance?.terminal.write(
        'PS C:\\src\\chitragupta\\chitragupta-app> flutter test\r\n'
        '\x1b[32m00:29 +1546 ~2: All tests passed!\x1b[0m\r\n'
        'PS C:\\src\\chitragupta\\chitragupta-app> git status --short\r\n'
        '\x1b[33m M\x1b[0m lib/src/app/shell/app_shell.dart\r\n'
        '\x1b[33m M\x1b[0m lib/src/app/theme/app_theme.dart\r\n'
        '\x1b[32m??\x1b[0m lib/src/app/shell/side_panel.dart\r\n'
        'PS C:\\src\\chitragupta\\chitragupta-app> ',
      );
    }
    final controller = container.read(sidePanelProvider.notifier);
    // `select` on the open surface collapses (that is the rail's gesture), so
    // drive it explicitly rather than through the toggle.
    controller.collapse();
    if (panel != null) controller.select(panel);
    await settle(tester);

    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });

    // Unmount before the container is disposed, or providers still finalising
    // reach for a dead Ref.
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  }

  const desktop = Size(1440, 900);

  testWidgets('light desktop', (tester) async {
    await shoot(
      tester,
      name: 'light-desktop',
      size: desktop,
      brightness: Brightness.light,
    );
  });

  testWidgets('dark desktop', (tester) async {
    await shoot(
      tester,
      name: 'dark-desktop',
      size: desktop,
      brightness: Brightness.dark,
    );
  });

  testWidgets('dark desktop, panel collapsed', (tester) async {
    await shoot(
      tester,
      name: 'dark-panel-collapsed',
      size: desktop,
      brightness: Brightness.dark,
      panel: null,
    );
  });

  testWidgets('dark session view', (tester) async {
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await shoot(
      tester,
      name: 'dark-session',
      size: desktop,
      brightness: Brightness.dark,
    );
  });

  testWidgets('narrow', (tester) async {
    await shoot(
      tester,
      name: 'light-narrow',
      size: const Size(700, 820),
      brightness: Brightness.light,
    );
  });
}
