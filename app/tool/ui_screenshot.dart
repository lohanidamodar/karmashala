// A throwaway harness: renders the real shell into PNGs so a layout and colour
// change can be *looked at*. Lives under tool/ so `flutter test` never picks it
// up; run it explicitly:
//
//   flutter test tool/ui_screenshot.dart
//
// Images land in build/ui-screenshots/.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:agent_cli/process.dart' show localHostEnvironment;
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala/src/features/git/application/diff_tab_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/editor/application/editor_tab_actions.dart';
import 'package:karmashala/src/features/editor/application/open_documents.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../test/features/terminal/fake_instance.dart';
import '../test/support/fake_command_runner.dart';
import '../test/support/fake_data_server.dart';
import '../test/support/fixtures.dart';
import '../test/support/memory_documents.dart';
import '../test/support/test_machine.dart';

const _outDir = 'build/ui-screenshots';

/// The Flutter SDK's bundled fonts on **this** machine, or null if they are not
/// where the SDK says they should be.
///
/// This used to be a hard-coded path into one developer's home directory, which
/// made the program silently useless anywhere else — `FontLoader` throws on a
/// missing file, out of `setUpAll`, before a single screenshot is taken.
/// `FLUTTER_ROOT` is set by the `flutter` tool for the processes it starts, and
/// this program is only ever run through `flutter test`.
String? _findFontDir() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null || root.isEmpty) return null;
  final dir = Directory(
    p.join(root, 'bin', 'cache', 'artifacts', 'material_fonts'),
  );
  return dir.existsSync() ? dir.path : null;
}

/// A monospace face to stand in for the terminal's. Optional: without it the
/// terminal panes render in the default face, which is worth less but is not
/// worth failing over.
String? _findMonoFont() {
  for (final candidate in [
    r'C:\Windows\Fonts\consola.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
    '/System/Library/Fonts/Menlo.ttc',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// flutter_test draws every glyph as a filled box unless real fonts are loaded,
/// which makes a screenshot useless for judging type and density.
Future<void> _loadFonts(String fontDir) async {
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
    'regular': '$fontDir/roboto-regular.ttf',
    'medium': '$fontDir/roboto-medium.ttf',
    'bold': '$fontDir/roboto-bold.ttf',
  });
  await load('MaterialIcons', {
    'regular': '$fontDir/materialicons-regular.otf',
  });
  final mono = _findMonoFont();
  if (mono != null) await load('monospace', {'regular': mono});
}

/// A file the editor scene opens, with no disk behind it.
const _sampleFile = r'C:\src\karmashala\lib\src\app\shell\side_panel.dart';
const _sampleSource = """

import 'package:karmashala_ui/tokens.dart';
import 'side_panel_state.dart';

/// The rail and the surface it opens, as one column. A surface draws its own
/// header; the rail only says which one is showing.
class SidePanel extends ConsumerWidget {
  const SidePanel({required this.surface, super.key});

  final SidePanelSurface? surface;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (surface == null) return const SizedBox(width: Chrome.rail);
    return Row(
      children: [
        const SidePanelRail(),
        SizedBox(
          width: ref.watch(sidePanelWidthProvider),
          child: DecoratedBox(
            decoration: BoxDecoration(color: theme.colorScheme.surface),
            child: surface!.build(context),
          ),
        ),
      ],
    );
  }
}
""";

/// A review's worth of changed files, for the Changes panel's scene.
const _changedFiles = [
  FileChange(
    path: 'lib/src/app/shell/side_panel.dart',
    type: FileChangeType.modified,
    staged: false,
    unstaged: true,
  ),
  FileChange(
    path: 'lib/src/features/git/presentation/diff_tab_view.dart',
    type: FileChangeType.added,
    staged: true,
    unstaged: false,
  ),
  FileChange(
    path: 'lib/src/features/git/presentation/changes_view.dart',
    type: FileChangeType.modified,
    staged: false,
    unstaged: true,
  ),
  FileChange(
    path: 'test/features/git/diff_tab_test.dart',
    type: FileChangeType.untracked,
    staged: false,
    unstaged: true,
  ),
  FileChange(
    path: 'pubspec.lock',
    type: FileChangeType.modified,
    staged: false,
    unstaged: true,
  ),
];

const _changeStats = {
  'lib/src/app/shell/side_panel.dart': FileDiffStat(added: 12, removed: 3),
  'lib/src/features/git/presentation/diff_tab_view.dart': FileDiffStat(
    added: 122,
    removed: 0,
  ),
  'lib/src/features/git/presentation/changes_view.dart': FileDiffStat(
    added: 61,
    removed: 496,
  ),
  'pubspec.lock': FileDiffStat(added: 2, removed: 2),
};

const _sampleDiff = """
@@ -18,9 +18,8 @@ class SidePanel extends ConsumerWidget {
   @override
   Widget build(BuildContext context, WidgetRef ref) {
     final theme = Theme.of(context);
-    if (surface == null) return const SizedBox(width: Chrome.rail);
-    return Row(
-      children: [
+    if (surface == null) return const SizedBox(width: Chrome.rail);
+    return Row(children: [
         const SidePanelRail(),
         SizedBox(
           width: ref.watch(sidePanelWidthProvider),
@@ -31,6 +30,5 @@ class SidePanel extends ConsumerWidget {
           ),
         ),
-      ],
-    );
+    ]);
   }
 }
""";

/// A file past kEditableSizeLimit, so the scene opens the read-only viewer.
final _bigFile = r'C:\src\karmashala\build\web\main.dart.js';
final _bigSource = List.generate(
  60000,
  (i) => "  var t$i = a$i.call(b$i, 'chunk-$i'); // minified line $i",
).join('\n');

/// Serves [_sampleSource] so the scene never touches a real file.
class _SampleStore extends DocumentStore {
  _SampleStore() : super(noServerFiles());

  @override
  Future<SourceDocument> load(String hostPath) async {
    final text = hostPath == _bigFile ? _bigSource : _sampleSource;
    return SourceDocument(
      hostPath: hostPath,
      text: text,
      savedText: text,
      language: 'dart',
      stamp: const FileStamp(length: 0, modified: null),
      mode: text.length > kEditableSizeLimit
          ? DocumentMode.view
          : DocumentMode.edit,
    );
  }
}

void main() {
  final fontDir = _findFontDir();
  if (fontDir == null) {
    testWidgets('the screenshot harness needs the Flutter SDK fonts', (
      tester,
    ) async {
      // `testWidgets` takes only a bool for `skip`, so the reason is recorded
      // the way the reporter shows it.
      markTestSkipped(
        'FLUTTER_ROOT is unset or its bin/cache/artifacts/material_fonts is '
        'missing. Run this through `flutter test tool/ui_screenshot.dart`, '
        'which sets FLUTTER_ROOT.',
      );
    });
    return;
  }

  late TestMachine db;
  late ProviderContainer container;

  setUpAll(() => _loadFonts(fontDir));

  setUp(() async {
    db = TestMachine();
    // The workspace, environments, installations and sessions are the
    // server's: seeded at a fake one.
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(localHostEnvironment(testTime));
    server.projectRows
      ..insert(
        project(id: 'p1', name: 'karmashala', path: r'C:\src\karmashala'),
      )
      ..insert(
        project(id: 'p2', name: 'meronepali', path: r'C:\src\meronepali'),
      );
    server.repositoryRows
      ..insert(repository(id: 'r1', projectId: 'p1', name: 'karmashala-app'))
      ..insert(repository(id: 'r2', projectId: 'p1', name: 'mcp_bridge'))
      ..insert(repository(id: 'r3', projectId: 'p2', name: 'app'));
    server.installationRows.insert(agentInstallation());
    server.sessionRows
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
        ...fakeTerminalOverrides(machine: db),
        await server.override(),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        documentStoreProvider.overrideWithValue(_SampleStore()),
        repositoryChangesProvider.overrideWith((ref) async => _changedFiles),
        repositoryFileDiffStatsProvider.overrideWith(
          (ref) async => _changeStats,
        ),
        repoWorktreesProvider.overrideWith((ref) async => const []),
        diffForTargetProvider.overrideWith((ref, target) async => _sampleDiff),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        sessionTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
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

  Future<void> shoot(
    WidgetTester tester, {
    required String name,
    required Size size,
    required Brightness brightness,
    SidePanelSurface? panel = SidePanelSurface.changes,

    /// Runs once the shell is mounted and the panel is set, so a frame can put
    /// the app into a state (an inbox with something in it, quick open showing)
    /// before the pixels are taken.
    Future<void> Function(WidgetTester tester)? afterMount,
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
        child: RepaintBoundary(key: key, child: const KarmashalaApp()),
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
        'PS C:\\src\\karmashala\\karmashala-app> flutter test\r\n'
        '\x1b[32m00:29 +1546 ~2: All tests passed!\x1b[0m\r\n'
        'PS C:\\src\\karmashala\\karmashala-app> git status --short\r\n'
        '\x1b[33m M\x1b[0m lib/src/app/shell/app_shell.dart\r\n'
        '\x1b[33m M\x1b[0m packages/karmashala_ui/lib/src/app_theme.dart\r\n'
        '\x1b[32m??\x1b[0m lib/src/app/shell/side_panel.dart\r\n'
        'PS C:\\src\\karmashala\\karmashala-app> ',
      );
    }
    final controller = container.read(sidePanelProvider.notifier);
    // `select` on the open surface collapses (that is the rail's gesture), so
    // drive it explicitly rather than through the toggle.
    controller.collapse();
    if (panel != null) controller.select(panel);
    await settle(tester);
    if (afterMount != null) {
      await afterMount(tester);
      await settle(tester);
    }

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

  testWidgets('dark attention inbox', (tester) async {
    await shoot(
      tester,
      name: 'dark-inbox',
      size: desktop,
      brightness: Brightness.dark,
      panel: SidePanelSurface.inbox,
      afterMount: (tester) async {
        const key = AgentSessionKey(AgentIds.claudeCode, 'cli-1');
        const other = AgentSessionKey(AgentIds.claudeCode, 'cli-2');
        FakeDataServer.of(container.read(dataClientProvider)).attention.apply(
              InboxUpdate(
                watched: {key, other},
                waiting: const [
                  SessionAttention(
                    session: WatchedSession(
                      key: other,
                      label: 'Fix the scrollback restore',
                      openId: 's2',
                      imported: false,
                    ),
                    kind: AttentionKind.needsInput,
                  ),
                ],
                news: const [
                  (
                    session: WatchedSession(
                      key: key,
                      label: 'Overhaul the desktop UI',
                      openId: 's1',
                      imported: false,
                    ),
                    reason: NotificationReason.finished,
                  ),
                ],
              ),
            );
      },
    );
  });

  testWidgets('dark quick open', (tester) async {
    await shoot(
      tester,
      name: 'dark-quick-open',
      size: desktop,
      brightness: Brightness.dark,
      panel: null,
      afterMount: (tester) async {
        container.read(selectedRepositoryIdProvider.notifier).select('r1');
        final context = tester.element(find.byType(WorkbenchView));
        unawaited(QuickOpen.show(context));
        await tester.pump();
        // The dialog's own field, not the Explorer's search box — which is
        // also a TextField and is the one `.first` finds.
        await tester.enterText(
          find.descendant(
            of: find.byType(QuickOpen),
            matching: find.byType(TextField),
          ),
          'des',
        );
        await tester.pump();
      },
    );
  });

  Future<void> openTheEditor(WidgetTester tester) async {
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    container.read(editorTabActionsProvider).open(_sampleFile);
    await tester.pump();
  }

  testWidgets('dark editor', (tester) async {
    await shoot(
      tester,
      name: 'dark-editor',
      size: desktop,
      brightness: Brightness.dark,
      panel: SidePanelSurface.files,
      afterMount: openTheEditor,
    );
  });

  testWidgets('light editor', (tester) async {
    await shoot(
      tester,
      name: 'light-editor',
      size: desktop,
      brightness: Brightness.light,
      panel: SidePanelSurface.files,
      afterMount: openTheEditor,
    );
  });

  // The unsaved mark on the tab chip and in the pane header, which is the one
  // thing on this surface that has to be legible at a glance.
  testWidgets('dark editor, unsaved', (tester) async {
    await shoot(
      tester,
      name: 'dark-editor-unsaved',
      size: desktop,
      brightness: Brightness.dark,
      panel: null,
      afterMount: (tester) async {
        await openTheEditor(tester);
        container
            .read(openDocumentsProvider.notifier)
            .edit(_sampleFile, '$_sampleSource\n// edited, not saved\n');
        await tester.pump();
      },
    );
  });

  testWidgets('dark changes and a diff tab', (tester) async {
    await shoot(
      tester,
      name: 'dark-diff',
      size: desktop,
      brightness: Brightness.dark,
      panel: SidePanelSurface.changes,
      afterMount: (tester) async {
        container.read(selectedProjectIdProvider.notifier).select('p1');
        container.read(selectedRepositoryIdProvider.notifier).select('r1');
        await tester.pump();
        container
            .read(diffTabActionsProvider)
            .open('lib/src/app/shell/side_panel.dart');
        await tester.pump();
      },
    );
  });

  testWidgets('dark editor, a file too big to edit', (tester) async {
    await shoot(
      tester,
      name: 'dark-editor-readonly',
      size: desktop,
      brightness: Brightness.dark,
      panel: null,
      afterMount: (tester) async {
        container.read(editorTabActionsProvider).open(_bigFile);
        await tester.pump();
      },
    );
  });

  testWidgets('narrow editor', (tester) async {
    await shoot(
      tester,
      name: 'light-editor-narrow',
      size: const Size(700, 820),
      brightness: Brightness.light,
      panel: null,
      afterMount: (tester) async {
        await openTheEditor(tester);
        // A narrow shell opens on the Explorer; the editor is behind the other
        // half of its bottom switch.
        await tester.tap(find.text('Workbench'));
        await tester.pump();
      },
    );
  });
}
