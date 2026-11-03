import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_providers.dart';
import 'package:karmashala/src/features/overview/presentation/overview_peek.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala/src/features/sessions/presentation/approval_request_card.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/sessions/presentation/shown_chat.dart';

import 'mission_fixture.dart';

/// **The dashboard's chat shows what its session waits on**, over its box as
/// the bot's approvals are: a prompt read off the screen, with no call to
/// hang it under — Codex's, whose hooks never say a prompt is open — was in
/// no card there, only in a popup with its last line and no buttons (owner,
/// 2026-11-03).
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-peek-ask');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  final now = MissionFixture.now;
  const id = 'codex-run';
  final asking = AgentStatusReport(
    agentId: AgentIds.codex,
    sessionId: 'cli-$id',
    status: AgentActivityStatus.awaitingApproval,
    observedAt: now,
    source: AgentStatusSource.terminalGrid,
    waiting: AgentWaitKind.approval,
    waitingSince: now.subtract(const Duration(minutes: 1)),
    evidence: const [
      'Would you like to run the following command?',
      r'$ git switch -c feature/typing-games',
      'Press enter to confirm or esc to cancel',
    ],
  );

  /// The peek, its chat a stand-in shaped as the real one's footer: the
  /// lead the real chat is given, then the box under it.
  Future<Widget?> pumpPeek(
    WidgetTester tester, {
    required AgentStatusReport? report,
  }) async {
    Widget? lead;
    final c = await pumpMission(
      tester,
      fixture: MissionFixture(
        sessions: [
          (
            id: id,
            title: 'Typing games',
            project: 'p-beej',
            machine: 'windows',
            agent: AgentIds.codex,
            state: report == null ? AgentState.working : AgentState.needsYou,
            age: const Duration(minutes: 3),
            parent: null,
            report: report,
          ),
        ],
        peekChat: (entry, seenUntil) {
          final real = overviewPeekChat(entry, seenUntil);
          lead = (real as SessionTranscriptView).footerLead;
          // As the real one: the messages take what the footer leaves, and
          // the footer, bounded, is only as tall as what it holds.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Expanded(child: SizedBox.expand()),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 500),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ?lead,
                    const SizedBox(key: ValueKey('box'), height: 80),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      prefsDir: dir,
      size: const Size(1440, 900),
      waiting: true,
      overrides: [sessionAnswerableProvider.overrideWithValue((_) => true)],
    );
    c.read(overviewFocusProvider.notifier).peek(id);
    await settleMission(tester);
    return lead;
  }

  testWidgets('the real chat is given what it waits on over its box', (
    tester,
  ) async {
    final lead = await pumpPeek(tester, report: asking);
    expect(lead, isA<OverviewPeekAsk>());
    await unmountMission(tester);
  });

  testWidgets('a prompt with no call is answered over the box', (tester) async {
    await pumpPeek(tester, report: asking);
    final peek = find.byKey(const ValueKey('overview-peek'));
    final card = find.descendant(
      of: peek,
      matching: find.byType(ApprovalRequestCard),
    );
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: peek, matching: find.textContaining('git switch')),
      findsWidgets,
    );
    final box = find.byKey(const ValueKey('box'));
    expect(
      tester.getRect(card).bottom,
      lessThanOrEqualTo(tester.getTopLeft(box).dy),
    );
    await unmountMission(tester);
  });

  // The dock once sat in a Flexible beside the chat's Expanded, which kept
  // half the peek for it even when nothing waited: the chat and its box
  // stopped halfway down (owner, 2026-11-03).
  testWidgets('with nothing waiting the chat fills the peek', (tester) async {
    await pumpPeek(tester, report: null);
    final body = find.byKey(const ValueKey('overview-peek-body'));
    final chat = find.descendant(
      of: body,
      matching: find.byType(ChatShownOutsideGroups),
    );
    expect(chat, findsOneWidget);
    expect(tester.getRect(chat).bottom, tester.getRect(body).bottom);
    expect(
      tester.getRect(find.byKey(const ValueKey('box'))).bottom,
      tester.getRect(body).bottom,
    );
    await unmountMission(tester);
  });
}
