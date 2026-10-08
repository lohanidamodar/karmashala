import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_batch.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';

import 'mission_fixture.dart';

class _SpyActions extends SessionActions {
  _SpyActions(super.ref, this.sent);

  final List<(String, String)> sent;

  @override
  Future<void> continueSession(
    String sessionId,
    String text, {
    String? requestId,
  }) async => sent.add((sessionId, text));
}

class _Recorder implements PromptAnswering {
  final asked = <PromptAnswerRequest>[];

  @override
  Future<SessionApprovalAnswer> answer(PromptAnswerRequest request) async {
    asked.add(request);
    return const SessionApprovalAnswer(answered: 'ok', effect: 'ok');
  }

  @override
  Future<PromptEvidence> evidence(String sessionId) =>
      throw UnimplementedError();

  @override
  AgentScreenMenu? menuOnScreen(String sessionId) => null;
}

/// **Batch replies**: pick several waiting sessions, then message them all,
/// or allow or deny them all — only when every one asks the very same
/// command in the very same folder.
void main() {
  final now = MissionFixture.now;
  AgentStatusReport asks(String command, {String cwd = '/src/ks'}) =>
      AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: 'cli',
        status: AgentActivityStatus.awaitingApproval,
        observedAt: now,
        source: AgentStatusSource.hook,
        waiting: AgentWaitKind.approval,
        waitingSince: now.subtract(const Duration(minutes: 2)),
        toolAsk: AgentToolAsk(
          toolName: 'Bash',
          input: {'command': command},
          at: now,
          cwd: cwd,
          options: const [
            AgentToolAskOption(id: 'ok', name: 'Allow', kind: 'allow_once'),
            AgentToolAskOption(id: 'no', name: 'Reject', kind: 'reject_once'),
          ],
        ),
      );

  group('which approvals are batched', () {
    final reports = {
      'a': asks('flutter test'),
      'b': asks('flutter test'),
      'c': asks('rm -rf build'),
      'd': asks('flutter test', cwd: '/src/other'),
    };
    AgentStatusReport? statusOf(String id) => reports[id];

    test('the same exact command in the same folder is one approval', () {
      final shared = sharedBatchApproval(['a', 'b'], statusOf: statusOf);
      expect(shared?.subject, 'flutter test');
      expect(shared?.folder, '/src/ks');
    });

    test('a different command, a different folder, or no approval is '
        'never batched', () {
      expect(sharedBatchApproval(['a', 'c'], statusOf: statusOf), isNull);
      expect(sharedBatchApproval(['a', 'd'], statusOf: statusOf), isNull);
      expect(sharedBatchApproval(['a', 'x'], statusOf: statusOf), isNull);
    });
  });

  group('the selection', () {
    test('toggles, extends from the last pick, and clears', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final keep = container.listen(overviewSelectionProvider, (_, _) {});
      addTearDown(keep.close);
      final selection = container.read(overviewSelectionProvider.notifier);
      selection.toggle('b');
      selection.extendTo('d', ['a', 'b', 'c', 'd', 'e']);
      expect(container.read(overviewSelectionProvider).ids, {'b', 'c', 'd'});
      selection.toggle('c');
      expect(container.read(overviewSelectionProvider).ids, {'b', 'd'});
      selection.clear();
      expect(container.read(overviewSelectionProvider).isEmpty, isTrue);
    });
  });

  group('on the board', () {
    late Directory dir;
    late _Recorder recorder;
    final sent = <(String, String)>[];

    setUp(() async {
      sent.clear();
      recorder = _Recorder();
      dir = await Directory.systemTemp.createTemp('ks-batch');
    });
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold the prefs file; the OS sweeps temp.
      }
    });

    MissionSession waiting(String id, String title, AgentStatusReport report) =>
        (
          id: id,
          title: title,
          project: 'p-ks',
          machine: 'windows',
          agent: AgentIds.claudeCode,
          state: AgentState.needsYou,
          age: const Duration(minutes: 2),
          parent: null,
          report: report,
        );

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      Size size = const Size(1440, 900),
      bool phone = false,
    }) => pumpMission(
      tester,
      fixture: MissionFixture(
        sessions: [
          waiting('r21', 'Round 21', asks('flutter test')),
          waiting('r22', 'Round 22', asks('flutter test')),
          waiting('r23', 'Round 23', asks('rm -rf build')),
          for (final s in MissionFixture.realisticSessions())
            if (s.id == 'ks-release') s,
        ],
      ),
      prefsDir: dir,
      size: size,
      phone: phone,
      overrides: [
        sessionActionsProvider.overrideWith((ref) => _SpyActions(ref, sent)),
        sessionAnswerableProvider.overrideWithValue((_) => true),
        sessionPromptAnswersProvider.overrideWithValue(recorder),
      ],
    );

    Finder box(String id) => find.byKey(ValueKey('overview-select:$id'));
    final bar = find.byKey(const ValueKey('overview-batch-bar'));

    Future<void> pick(WidgetTester tester, String id) async {
      await tester.ensureVisible(box(id));
      await tester.tap(box(id));
      await settleMission(tester);
    }

    testWidgets('the boxes show on what waits, and the bar only once some '
        'are picked', (tester) async {
      await pump(tester);
      expect(box('r21'), findsOneWidget);
      expect(box('ks-release'), findsNothing);
      expect(bar, findsNothing);

      await pick(tester, 'r21');
      expect(bar, findsOneWidget);
      expect(find.text('1 selected'), findsOneWidget);
      // While picking, every card can join.
      expect(box('ks-release'), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('Allow N is offered for one command and asks first, naming '
        'the command and the sessions', (tester) async {
      await pump(tester);
      await pick(tester, 'r21');
      await pick(tester, 'r22');

      expect(find.text('Allow 2'), findsOneWidget);
      expect(find.text('Deny 2'), findsOneWidget);
      await tester.tap(find.text('Allow 2'));
      await settleMission(tester);

      expect(find.text('Allow 2 sessions to run this?'), findsOneWidget);
      expect(find.textContaining('flutter test\nin /src/ks'), findsOneWidget);
      expect(find.textContaining('• Round 21'), findsOneWidget);
      expect(find.textContaining('• Round 22'), findsOneWidget);
      expect(recorder.asked, isEmpty);

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Allow 2'),
        ),
      );
      await settleMission(tester);
      expect(
        [
          for (final r in recorder.asked.cast<ApprovalAnswerRequest>())
            (r.sessionId, r.optionId),
        ],
        [('r21', 'ok'), ('r22', 'ok')],
      );
      expect(bar, findsNothing);
      await unmountMission(tester);
    });

    testWidgets('approvals that differ are never batched', (tester) async {
      await pump(tester);
      await pick(tester, 'r21');
      await pick(tester, 'r23');

      expect(find.text('Allow 2'), findsNothing);
      expect(find.text('Deny 2'), findsNothing);
      expect(find.text('Different commands — answer each'), findsOneWidget);
      expect(find.text('Send a message to 2'), findsOneWidget);
      await unmountMission(tester);
    });

    testWidgets('a message goes to every one picked', (tester) async {
      await pump(tester);
      await pick(tester, 'r21');
      await pick(tester, 'r23');

      await tester.tap(find.text('Send a message to 2'));
      await settleMission(tester);
      await tester.enterText(
        find.byKey(const ValueKey('overview-batch-text')),
        'Stop and summarise',
      );
      await settleMission(tester);
      await tester.tap(find.byKey(const ValueKey('overview-batch-send')));
      await settleMission(tester);

      expect(sent, [
        ('r21', 'Stop and summarise'),
        ('r23', 'Stop and summarise'),
      ]);
      expect(bar, findsNothing);
      await unmountMission(tester);
    });

    testWidgets('Ctrl-click picks, Shift-click spans, Esc clears', (
      tester,
    ) async {
      await pump(tester);
      Future<void> clickWith(LogicalKeyboardKey key, String id) async {
        final title = find.byKey(ValueKey('overview-queue-title:$id'));
        await tester.ensureVisible(title);
        await tester.sendKeyDownEvent(key);
        await tester.tap(title);
        await tester.sendKeyUpEvent(key);
        await settleMission(tester);
      }

      await clickWith(LogicalKeyboardKey.controlLeft, 'r21');
      expect(find.text('1 selected'), findsOneWidget);
      await clickWith(LogicalKeyboardKey.shiftLeft, 'r23');
      expect(find.text('3 selected'), findsOneWidget);
      // Picking is not opening.
      expect(find.byKey(const ValueKey('overview-peek')), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleMission(tester);
      expect(bar, findsNothing);
      await unmountMission(tester);
    });

    testWidgets('on the phone a long press picks and the bar fits', (
      tester,
    ) async {
      await pump(tester, size: const Size(360, 780), phone: true);
      await pick(tester, 'r21');
      expect(find.text('1 selected'), findsOneWidget);
      final row = find.byKey(const ValueKey('overview-phone-row:ks-release'));
      await tester.scrollUntilVisible(row, 200, scrollable: hybridList);
      await tester.ensureVisible(row);
      await settleMission(tester);
      await tester.longPress(row);
      await settleMission(tester);
      expect(find.text('2 selected'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmountMission(tester);
    });
  });
}
