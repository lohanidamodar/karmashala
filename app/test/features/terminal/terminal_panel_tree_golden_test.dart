import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/media/video_support_provider.dart';
import 'package:karmashala_media/media.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_recording_controller.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/application/terminal_search_controller.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_pane_view.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:xterm2/xterm.dart';

import '../../support/fakes.dart';
import 'fake_instance.dart';

/// The terminal panel's rendered widget tree, frozen for its main states.
///
/// `terminal_panel.dart` composes a dozen widgets — the pane stack, the
/// regions, the status and recording bars, the toolbar, the tab chip, the two
/// right-click menus, the floating pane handle, the drop target — and every
/// ordinary test around it asserts one thing at a time: a label, a tap, a
/// count. None of them would notice a family arriving at a different depth, a
/// `Divider` lost on the way across, or a branch that used to be entered no
/// longer being entered. Splitting the file is meant to change none of that.
///
/// So the whole tree is committed: every element under the widget each state
/// names, with its widget type, its key, and the text, tooltip or icon it
/// carries. A refactor that does not touch behaviour leaves this file alone; a
/// change that does touch it has to be made deliberately, and the diff says
/// exactly what a user will see differently.
///
/// This is the same harness `device_pane_tree_golden_test.dart` uses, with one
/// addition: an [Icon]'s own `IconData` is recorded, because half of what the
/// two menus and the toolbar draw is glyphs and a menu row that changed its
/// icon would otherwise move nothing here.
///
/// What it cannot reach, deliberately:
///
/// * **The Settings document, shown.** `_buildPane` draws `SettingsTabView`
///   for the settings pane while its tab is in front, which is a whole other
///   screen's tree and every provider behind it. The hidden half of that
///   branch — a settings tab mounted behind another one — is captured, which
///   is the half `terminal_panel.dart` decides.
/// * **A hovered pane handle.** `_PaneFloatingActions` changes an opacity and
///   nothing else, and an opacity is not in the shape this dump records.
///
/// Regenerate only when the change is intended, and never as a side effect of
/// `--update-goldens` (which is why this is its own variable):
///
/// ```
/// KARMASHALA_WRITE_TERMINAL_PANEL_GOLDEN=1 flutter test \
///   test/features/terminal/terminal_panel_tree_golden_test.dart
/// ```
const _goldenPath = 'test/features/terminal/terminal_panel_tree.golden.txt';

const _desktop = Size(1280, 800);

/// Pinned, so the golden says the same thing on a host with a different
/// encoder: the pane menu names what a recording will be able to become.
const _noMp4 = VideoSupport.unavailable('pinned for the golden');

/// Object hashes are per-run. A key or a type that carries one is normalised so
/// the golden is about the shape, not about this process's addresses.
final _hash = RegExp(r'#[0-9a-f]{5}');

String _describe(Widget widget) {
  final buffer = StringBuffer(widget.runtimeType.toString());
  if (widget.key case final key?) buffer.write(' key=$key');
  switch (widget) {
    case Text(:final data?):
      buffer.write(' text=${_oneLine(data)}');
    case Tooltip(:final message?):
      buffer.write(' tooltip=${_oneLine(message)}');
    case Icon(:final icon?):
      buffer.write(' icon=$icon');
    case _:
      break;
  }
  return buffer.toString().replaceAll(_hash, '#…');
}

/// One line, whatever the string contains.
String _oneLine(String value) =>
    '"${value.replaceAll('\\', r'\\').replaceAll('\n', r'\n').replaceAll('"', r'\"')}"';

String _treeUnder(WidgetTester tester, Finder root) {
  final buffer = StringBuffer();
  void walk(Element element, int depth) {
    buffer
      ..write('  ' * depth)
      ..writeln(_describe(element.widget));
    element.visitChildren((child) => walk(child, depth + 1));
  }

  walk(tester.element(root), 0);
  return buffer.toString();
}

/// The open `showMenu` route, which is a sibling of the panel rather than a
/// child of it: both right-click menus are built into the overlay.
final _openMenu = find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString().startsWith('_PopupMenu<'),
);

/// A pane that was launched as an agent, so the dormant status bar takes its
/// "resume" branch rather than its "restart" one.
TerminalInstance _agentInstance({
  required String id,
  required TerminalProfile profile,
  String? workingDirectory,
  String? restoredScrollback,
  bool shellIntegration = false,
  AgentPaneLaunch? agentLaunch,
  Terminal? adoptTerminal,
}) => FakeTerminalInstance(
  id: id,
  title: 'claude',
  profileId: profile.id,
  workingDirectory: workingDirectory,
  agentLaunch: const AgentPaneLaunch(
    agentId: 'claude',
    executable: 'claude',
    sessionId: 'sess-1',
    title: 'claude',
  ),
);

void main() {
  // Pinned to the platform whose modifier the chords in these tooltips name,
  // exactly as `context_menu_design_test.dart` pins it: on macOS copy is `⌘C`,
  // and a golden that read the host would say something different per machine.
  setUp(() => commandKeyIsMeta = false);

  final captured = <String, String>{};

  ProviderContainer container({
    TerminalInstanceFactory? instanceFactory,
    bool shellIntegration = false,
  }) {
    final database = AppDatabase.memory();
    addTearDown(database.close);
    // Nothing here may write to the user's own recordings folder: starting a
    // recording resolves the destination, and a pane ending mid-recording
    // writes the cast out of its own `dispose`.
    final recordings = Directory.systemTemp.createTempSync('panel-golden');
    addTearDown(() {
      try {
        recordings.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows keeps a handle a moment longer; not what this file is about.
      }
    });
    final result = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(
          database: database,
          instanceFactory: instanceFactory,
          shellIntegration: shellIntegration,
        ),
        // Pane and tab ids land in the tree as keys, and a v4 UUID would move
        // every line of this file on every run.
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        notesEnabledProvider.overrideWithValue(true),
        videoSupportProvider.overrideWithValue(_noMp4),
        recordingsDirectoryProvider.overrideWith((ref) async => recordings),
      ],
    );
    addTearDown(result.dispose);
    return result;
  }

  Future<void> pump(
    WidgetTester tester,
    ProviderContainer scope,
    Widget child, {
    Size size = _desktop,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void capture(WidgetTester tester, String state, Finder root) {
    captured[state] = _treeUnder(tester, root);
  }

  final stack = find.byType(TerminalPaneStack);

  TerminalSessionsController sessionsOf(ProviderContainer scope) =>
      scope.read(terminalSessionsControllerProvider.notifier);

  String focusedPaneOf(ProviderContainer scope) =>
      scope.read(terminalSessionsControllerProvider).activeTab!.focusedPaneId;

  testWidgets('opening, before the workbench has had its one automatic open', (
    tester,
  ) async {
    final scope = container();
    await pump(tester, scope, const TerminalPaneStack(autoOpenDone: false));
    capture(tester, 'opening', stack);
  });

  testWidgets('no terminal open', (tester) async {
    final scope = container();
    await pump(tester, scope, const TerminalPaneStack());
    capture(tester, 'no terminal open', stack);
  });

  testWidgets('one live pane', (tester) async {
    final scope = container();
    sessionsOf(scope).openTab(TerminalProfile.powerShell);
    await pump(tester, scope, const TerminalPaneStack());
    capture(tester, 'one live pane', stack);
  });

  testWidgets('a group nobody is typing into', (tester) async {
    final scope = container();
    sessionsOf(scope).openTab(TerminalProfile.powerShell);
    await pump(tester, scope, const TerminalPaneStack(groupFocused: false));
    capture(tester, 'a group nobody is typing into', stack);
  });

  testWidgets('a pane whose process exited', (tester) async {
    final scope = container();
    sessionsOf(scope).openTab(TerminalProfile.powerShell);
    await pump(tester, scope, const TerminalPaneStack());
    final pane = sessionsOf(scope).instanceFor(focusedPaneOf(scope))!;
    (pane as FakeTerminalInstance).exitWith(1);
    await tester.pumpAndSettle();
    capture(tester, 'a pane whose process exited', stack);
  });

  testWidgets('a restored agent pane, which resumes rather than restarts', (
    tester,
  ) async {
    final scope = container(instanceFactory: _agentInstance);
    sessionsOf(scope).openTab(TerminalProfile.powerShell);
    await pump(tester, scope, const TerminalPaneStack());
    final pane = sessionsOf(scope).instanceFor(focusedPaneOf(scope))!;
    (pane as FakeTerminalInstance).exitWith(1);
    await tester.pumpAndSettle();
    capture(
      tester,
      'a restored agent pane, which resumes rather than restarts',
      stack,
    );
  });

  testWidgets('an empty split region', (tester) async {
    final scope = container();
    final sessions = sessionsOf(scope);
    sessions.openTab(TerminalProfile.powerShell);
    await pump(tester, scope, const TerminalPaneStack());
    sessions.splitPane(SplitAxis.horizontal);
    await tester.pumpAndSettle();
    capture(tester, 'an empty split region', stack);
  });

  testWidgets('a split of two live panes', (tester) async {
    final scope = container();
    final sessions = sessionsOf(scope);
    sessions.openTab(TerminalProfile.powerShell);
    await pump(tester, scope, const TerminalPaneStack());
    sessions.splitPaneWith(SplitAxis.vertical, TerminalProfile.commandPrompt);
    await tester.pumpAndSettle();
    capture(tester, 'a split of two live panes', stack);
  });

  testWidgets('a region of two panes, which draws its own strip', (
    tester,
  ) async {
    final scope = container();
    final sessions = sessionsOf(scope);
    final first = sessions.openTab(TerminalProfile.powerShell);
    sessions.openTab(TerminalProfile.commandPrompt);
    await pump(tester, scope, const TerminalPaneStack());
    // A second tab dropped into the first tab's region: one region, two panes.
    sessions.movePaneIntoRegion(
      focusedPaneOf(scope),
      scope
          .read(terminalSessionsControllerProvider)
          .tabs
          .firstWhere((tab) => tab.id == first)
          .focusedPaneId,
    );
    await tester.pumpAndSettle();
    capture(tester, 'a region of two panes, which draws its own strip', stack);
  });

  testWidgets('the search bar open over a pane', (tester) async {
    final scope = container();
    sessionsOf(scope).openTab(TerminalProfile.powerShell);
    await pump(tester, scope, const TerminalPaneStack());
    scope
        .read(terminalSearchControllerProvider.notifier)
        .open(focusedPaneOf(scope));
    await tester.pumpAndSettle();
    capture(tester, 'the search bar open over a pane', stack);
  });

  testWidgets('a settings document mounted behind the tab in front', (
    tester,
  ) async {
    final scope = container();
    final sessions = sessionsOf(scope);
    sessions.openSettingsTab();
    sessions.openTab(TerminalProfile.powerShell);
    await pump(tester, scope, const TerminalPaneStack());
    capture(
      tester,
      'a settings document mounted behind the tab in front',
      stack,
    );
  });

  testWidgets('the pane menu, with nothing selected', (tester) async {
    final scope = container();
    sessionsOf(scope).openTab(TerminalProfile.powerShell);
    await pump(tester, scope, const TerminalPaneStack());
    await tester.tapAt(const Offset(600, 400), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    capture(tester, 'the pane menu, with nothing selected', _openMenu);
  });

  testWidgets('the pane menu, over a selection in a split', (tester) async {
    final scope = container();
    final sessions = sessionsOf(scope);
    sessions.openTab(TerminalProfile.powerShell);
    await pump(tester, scope, const TerminalPaneStack());
    sessions.splitPaneWith(SplitAxis.horizontal, TerminalProfile.commandPrompt);
    await tester.pumpAndSettle();

    final pane = sessions.instanceFor(focusedPaneOf(scope))!;
    pane.terminal.write('a line worth keeping');
    await tester.pumpAndSettle();
    final buffer = pane.terminal.buffer;
    pane.controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(19, 0),
    );
    await tester.pumpAndSettle();

    await tester.tapAt(
      tester.getCenter(
        find.byWidgetPredicate(
          (widget) =>
              widget is TerminalPaneView && identical(widget.instance, pane),
        ),
      ),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    capture(tester, 'the pane menu, over a selection in a split', _openMenu);
  });

  testWidgets('a pane being recorded', (tester) async {
    final scope = container();
    sessionsOf(scope).openTab(TerminalProfile.powerShell);
    await pump(tester, scope, const TerminalPaneStack());
    scope.read(terminalRecordingProvider.notifier).start(focusedPaneOf(scope));
    await tester.pumpAndSettle();
    capture(tester, 'a pane being recorded', stack);
    // Released before the container is, so the cast is written from a pane
    // that still has a place to write to.
    unawaited(
      scope.read(terminalRecordingProvider.notifier).stop(focusedPaneOf(scope)),
    );
  });

  testWidgets('a pane dragged over the pane beside it', (tester) async {
    final scope = container();
    final sessions = sessionsOf(scope);
    sessions.openTab(TerminalProfile.powerShell);
    await pump(tester, scope, const TerminalPaneStack());
    final first = focusedPaneOf(scope);
    sessions.splitPaneWith(SplitAxis.horizontal, TerminalProfile.commandPrompt);
    await tester.pumpAndSettle();
    final dragged = focusedPaneOf(scope);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(paneDragHandleKey(dragged))),
    );
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(
        find.byWidgetPredicate(
          (widget) =>
              widget is TerminalPaneView &&
              identical(widget.instance, sessions.instanceFor(first)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    capture(tester, 'a pane dragged over the pane beside it', stack);
    // Cancelled rather than dropped: the drop would re-split the tab, and what
    // this state is about is the overlay while the pointer is still down.
    await gesture.cancel();
    await tester.pumpAndSettle();
  });

  testWidgets('the toolbar, with no tab to act on', (tester) async {
    final scope = container();
    await pump(tester, scope, const TerminalToolbar());
    capture(
      tester,
      'the toolbar, with no tab to act on',
      find.byType(TerminalToolbar),
    );
  });

  testWidgets('the toolbar, over a live pane', (tester) async {
    final scope = container();
    sessionsOf(scope).openTab(TerminalProfile.powerShell);
    await pump(tester, scope, const TerminalToolbar());
    capture(
      tester,
      'the toolbar, over a live pane',
      find.byType(TerminalToolbar),
    );
  });

  testWidgets('the toolbar, compact', (tester) async {
    final scope = container();
    sessionsOf(scope).openTab(TerminalProfile.powerShell);
    await pump(
      tester,
      scope,
      const TerminalToolbar(compact: true),
      size: const Size(480, 640),
    );
    capture(tester, 'the toolbar, compact', find.byType(TerminalToolbar));
  });

  testWidgets('a tab chip: live, selected, and where the typing goes', (
    tester,
  ) async {
    final scope = container();
    await pump(
      tester,
      scope,
      TerminalTabChip(
        title: 'PowerShell',
        liveness: PaneLiveness.live,
        selected: true,
        index: 0,
        tabCount: 3,
        onTap: () {},
        onClose: () {},
        onEnd: () {},
        onBulkClose: (_) {},
        onSavePreset: () {},
      ),
    );
    capture(
      tester,
      'a tab chip: live, selected, and where the typing goes',
      find.byType(TerminalTabChip),
    );
  });

  testWidgets('a tab chip: exited, unselected, no preset behind it', (
    tester,
  ) async {
    final scope = container();
    await pump(
      tester,
      scope,
      TerminalTabChip(
        title: 'cmd',
        liveness: PaneLiveness.exited,
        selected: false,
        accented: false,
        index: 2,
        tabCount: 3,
        onTap: () {},
        onClose: () {},
        onEnd: () {},
        onBulkClose: (_) {},
      ),
    );
    capture(
      tester,
      'a tab chip: exited, unselected, no preset behind it',
      find.byType(TerminalTabChip),
    );
  });

  testWidgets('a tab chip: an agent that needs the user', (tester) async {
    final scope = container();
    await pump(
      tester,
      scope,
      TerminalTabChip(
        title: 'claude',
        liveness: PaneLiveness.live,
        agentStatus: AgentActivityStatus.awaitingApproval,
        selected: true,
        index: 1,
        tabCount: 3,
        onTap: () {},
        onClose: () {},
        onEnd: () {},
        onBulkClose: (_) {},
      ),
    );
    capture(
      tester,
      'a tab chip: an agent that needs the user',
      find.byType(TerminalTabChip),
    );
  });

  testWidgets('a tab chip: a document, which has no liveness to report', (
    tester,
  ) async {
    final scope = container();
    await pump(
      tester,
      scope,
      TerminalTabChip(
        title: 'Settings',
        liveness: PaneLiveness.exited,
        icon: Icons.settings,
        selected: false,
        index: 0,
        tabCount: 1,
        onTap: () {},
        onClose: () {},
        onEnd: () {},
        onBulkClose: (_) {},
      ),
    );
    capture(
      tester,
      'a tab chip: a document, which has no liveness to report',
      find.byType(TerminalTabChip),
    );
  });

  testWidgets('the tab menu, on the first of three tabs', (tester) async {
    final scope = container();
    await pump(
      tester,
      scope,
      TerminalTabChip(
        title: 'PowerShell',
        liveness: PaneLiveness.live,
        selected: true,
        index: 0,
        tabCount: 3,
        onTap: () {},
        onClose: () {},
        onEnd: () {},
        onBulkClose: (_) {},
        onSavePreset: () {},
      ),
    );
    await tester.tap(find.byType(TerminalTabChip), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    capture(tester, 'the tab menu, on the first of three tabs', _openMenu);
  });

  // Declared last so every state above has been captured by the time it runs.
  test('the panel renders the committed tree', () {
    final encoded = StringBuffer(
      '# The terminal panel\'s rendered widget tree, per state.\n'
      '# Regenerate with KARMASHALA_WRITE_TERMINAL_PANEL_GOLDEN=1; see\n'
      '# test/features/terminal/terminal_panel_tree_golden_test.dart.\n',
    );
    for (final state in captured.keys.toList()..sort()) {
      encoded
        ..writeln()
        ..writeln('== $state ==')
        ..write(captured[state]);
    }
    final file = File(_goldenPath);
    if (Platform.environment['KARMASHALA_WRITE_TERMINAL_PANEL_GOLDEN'] == '1') {
      file.writeAsStringSync(encoded.toString());
      // ignore: avoid_print
      print('wrote $_goldenPath');
    }
    expect(
      file.existsSync(),
      isTrue,
      reason: '$_goldenPath is missing; see the header of this file',
    );
    expect(
      encoded.toString(),
      file.readAsStringSync(),
      reason:
          'The panel renders a different tree. If that was intended, '
          'regenerate the golden; if it was a refactor, something moved that '
          'should not have.',
    );
  });
}
