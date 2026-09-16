import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/application/terminal_theme_controller.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The workbench's rendered widget tree, frozen for its main states.
///
/// `workbench.dart` composes a dozen private widgets — the tab strip and its
/// rail, the chip and its drop target, the two surfaces, the session bar and
/// its held-height box, the view toggle — and every ordinary test in
/// `test/app/shell/**` asserts one thing at a time: a label, a tap, a count.
/// None of them would notice a family arriving at a different depth, a
/// `Divider` lost on the way across, or a branch that used to be entered no
/// longer being entered. Splitting the file is meant to change none of that.
///
/// So the whole tree is committed: every element under [WorkbenchView], with
/// its widget type, its key, and the text or tooltip it carries. A refactor
/// that does not touch behaviour leaves this file alone; a change that does
/// touch it has to be made deliberately, and the diff says exactly what a user
/// will see differently.
///
/// Ids are pinned rather than normalised — [SequentialIdGenerator] gives every
/// tab, group and pane the same name on every run — so a key in the dump names
/// a real thing instead of a placeholder.
///
/// What it cannot reach: anything drawn in an `Overlay` rather than under the
/// workbench. `_TabDragFeedback` rides the pointer in the app's overlay, so the
/// drag state below captures the strip's *drop marker* and not the thing being
/// dragged. The settings tab's own page is a whole feature's tree and is
/// deliberately left off the active surface here; what this file is about is
/// the workbench's chrome around it, so that state shows the strip with the
/// settings chip in it.
///
/// Regenerate only when the change is intended, and never as a side effect of
/// `--update-goldens` (which is why this is its own variable):
///
/// ```
/// KARMASHALA_WRITE_WORKBENCH_GOLDEN=1 flutter test \
///   test/app/shell/workbench_tree_golden_test.dart
/// ```
const _goldenPath = 'test/app/shell/workbench_tree.golden.txt';

const _desktop = Size(1400, 900);
const _narrow = Size(760, 620);

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  final captured = <String, String>{};

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        // Every id in the dump is a name a reader can follow between states.
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        // The usage chip reports the *age* of its reading, so an unpinned clock
        // rewrites this file every hour on its own — a golden that fails for
        // the time of day teaches everyone to regenerate it without looking.
        clockProvider.overrideWithValue(FixedClock(testTime)),
        // Nothing here may reach the host: the bar's delivery line, the
        // transcript header's terminal list and the theme scan all would.
        sessionTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        discoveredTerminalThemesProvider.overrideWithValue(const []),
        // One fixed reading, so the bar draws its settled height rather than
        // whatever a race decided this run.
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery(branch: 'work'),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeCode,
              sessionId: id,
              status: AgentActivityStatus.idle,
              observedAt: testTime,
              source: AgentStatusSource.terminalGrid,
              evidence: const [],
              waiting: AgentWaitKind.unrecorded,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  TerminalSessionsController terminals() =>
      container.read(terminalSessionsControllerProvider.notifier);

  /// A tab of its own, running session [id].
  String openSessionTab(String id, {String title = 'Refactor the parser'}) {
    final tabId = terminals().openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((tab) => tab.id == tabId)
        .layout
        .panes
        .single;
    final dao = SessionDao(db)..insert(session(id: id, title: title));
    dao.updatePaneId(id, paneId);
    return tabId;
  }

  Future<void> pump(WidgetTester tester, {Size size = _desktop}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  void capture(WidgetTester tester, String state) =>
      captured[state] = _tree(tester);

  testWidgets('01 one terminal tab', (tester) async {
    terminals().openTab(TerminalProfile.powerShell);
    await pump(tester);
    capture(tester, '01 one terminal tab');
  });

  testWidgets('02 two tabs, the second active', (tester) async {
    terminals().openTab(TerminalProfile.powerShell);
    terminals().openTab(TerminalProfile.commandPrompt);
    await pump(tester);
    capture(tester, '02 two tabs, the second active');
  });

  testWidgets('03 a workspace split in two groups', (tester) async {
    final first = terminals().openTab(TerminalProfile.powerShell);
    terminals().openTab(TerminalProfile.commandPrompt);
    final right = terminals().splitWorkspace(SplitAxis.horizontal)!;
    terminals().moveTabToGroup(first, right);
    await pump(tester);
    capture(tester, '03 a workspace split in two groups');
  });

  testWidgets('04 an empty group', (tester) async {
    terminals().openTab(TerminalProfile.powerShell);
    terminals().splitWorkspace(SplitAxis.horizontal);
    await pump(tester);
    capture(tester, '04 an empty group');
  });

  testWidgets('05 a session on its terminal', (tester) async {
    openSessionTab('s1');
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester);
    capture(tester, '05 a session on its terminal');
  });

  testWidgets('06 the conversation face up', (tester) async {
    openSessionTab('s1');
    await pump(tester);
    terminals().showFaceIn(
      container.read(focusedWorkspaceGroupProvider)!,
      terminal: false,
    );
    await tester.pumpAndSettle();
    capture(tester, '06 the conversation face up');
  });

  testWidgets('07 a session with no pane of ours', (tester) async {
    terminals().openTab(TerminalProfile.powerShell);
    SessionDao(db).insert(session(id: 's9', title: 'Ended yesterday'));
    await pump(tester);
    container.read(selectedSessionIdProvider.notifier).select('s9');
    await tester.pumpAndSettle();
    capture(tester, '07 a session with no pane of ours');
  });

  testWidgets('08 a narrow group', (tester) async {
    openSessionTab('s1');
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await pump(tester, size: _narrow);
    capture(tester, '08 a narrow group');
  });

  testWidgets('09 more tabs than the strip fits', (tester) async {
    for (var i = 0; i < 12; i++) {
      terminals().openTab(TerminalProfile.powerShell);
    }
    await pump(tester, size: _narrow);
    capture(tester, '09 more tabs than the strip fits');
  });

  testWidgets('10 a tab dragged over its neighbour', (tester) async {
    terminals().openTab(TerminalProfile.powerShell);
    terminals().openTab(TerminalProfile.commandPrompt);
    await pump(tester);

    final chips = find.byType(TerminalTabChip);
    final gesture = await _dragFrom(
      tester,
      tester.getCenter(chips.at(1)),
      tester.getCenter(chips.at(0)),
    );
    capture(tester, '10 a tab dragged over its neighbour');
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('11 a settings tab in the strip', (tester) async {
    final terminal = terminals().openTab(TerminalProfile.powerShell);
    terminals().openSettingsTab();
    // The page itself is a whole feature's tree and is not what this file is
    // about; the chip it puts in the strip is.
    terminals().activateTab(terminal);
    await pump(tester);
    capture(tester, '11 a settings tab in the strip');
  });

  // Declared last so every state above has been captured by the time it runs.
  test('the workbench renders the committed tree', () {
    final encoded = StringBuffer(
      "# The workbench's rendered widget tree, per state.\n"
      '# Regenerate with KARMASHALA_WRITE_WORKBENCH_GOLDEN=1; see\n'
      '# test/app/shell/workbench_tree_golden_test.dart.\n',
    );
    for (final state in captured.keys.toList()..sort()) {
      encoded
        ..writeln()
        ..writeln('== $state ==')
        ..write(captured[state]);
    }
    final file = File(_goldenPath);
    if (Platform.environment['KARMASHALA_WRITE_WORKBENCH_GOLDEN'] == '1') {
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
          'The workbench renders a different tree. If that was intended, '
          'regenerate the golden; if it was a refactor, something moved that '
          'should not have.',
    );
  });
}

/// Stepped rather than jumped, so the drag really starts: a `Draggable` waits
/// for the pointer to pass the slop before it hands anything to a target.
Future<TestGesture> _dragFrom(
  WidgetTester tester,
  Offset from,
  Offset to,
) async {
  final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  await tester.pump();
  for (var step = 1; step <= 20; step++) {
    await gesture.moveTo(Offset.lerp(from, to, step / 20)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  return gesture;
}

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
    case _:
      break;
  }
  return buffer.toString().replaceAll(_hash, '#…');
}

/// One line, whatever the string contains.
String _oneLine(String value) =>
    '"${value.replaceAll('\\', r'\\').replaceAll('\n', r'\n').replaceAll('"', r'\"')}"';

String _tree(WidgetTester tester) {
  final buffer = StringBuffer();
  void walk(Element element, int depth) {
    buffer
      ..write('  ' * depth)
      ..writeln(_describe(element.widget));
    element.visitChildren((child) => walk(child, depth + 1));
  }

  walk(tester.element(find.byType(WorkbenchView)), 0);
  return buffer.toString();
}
