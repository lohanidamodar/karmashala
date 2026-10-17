import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_session/events.dart';

/// Claude Code 2.1.287's project-MCP checklist as a pane that answers keys the
/// way the real one did in a ConPTY probe (2026-10-08): ↓/↑ move the
/// highlight, ↑ on the first server wraps to the last server, ↓ stops on
/// "Enable selected", Space toggles a server's box, Enter on "Enable selected"
/// and Esc both close it.
class FakeChecklistPane {
  FakeChecklistPane(this.servers, {List<bool>? ticks})
    : ticks = ticks ?? [for (final _ in servers) true];

  final List<String> servers;
  final List<bool> ticks;
  int highlighted = 0;
  final List<String> pressed = [];

  /// What closed it: the ticks Enter submitted, or `rejected`.
  Object? closedWith;

  /// When false, Space does nothing: a pane that did not take the key.
  bool toggles = true;

  /// When false, Enter and Esc do nothing.
  bool closes = true;

  int get _submit => servers.length;

  List<String>? get screen => closedWith != null
      ? const ['❯ ', '  ⏸ manual mode on · ? for shortcuts']
      : [
          '  ${servers.length} new MCP servers found in this project',
          '  Select any you wish to enable.',
          '',
          '  MCP servers may execute code or access system resources.',
          '',
          for (var i = 0; i < servers.length; i++)
            '  ${i == highlighted ? '❯' : ' '} '
                '${ticks[i] ? '[✔]' : '[ ]'} ${servers[i]}',
          '  ${highlighted == _submit ? '❯' : ' '}    Enable selected',
          ' Space to select · Esc to reject all',
        ];

  bool press(String keys) {
    pressed.add(keys);
    if (closedWith != null) return true;
    switch (keys) {
      case '\x1b[B':
        if (highlighted < _submit) highlighted++;
      case '\x1b[A':
        highlighted = highlighted == 0 ? servers.length - 1 : highlighted - 1;
      case ' ' when toggles && highlighted < _submit:
        ticks[highlighted] = !ticks[highlighted];
      case '\r' when closes && highlighted == _submit:
        closedWith = List.of(ticks);
      case '\x1b' when closes:
        closedWith = 'rejected';
    }
    return true;
  }
}

class _Terminals implements PromptTerminals {
  _Terminals(this.pane);

  final FakeChecklistPane pane;
  final List<DecisionRecord> recorded = [];

  /// The rows the status quotes off the screen, as its grid source keeps them.
  List<String> evidence = const [];

  @override
  bool exists(String sessionId) => sessionId == 's1';

  @override
  AgentDescriptor? agentOf(String sessionId) =>
      AgentRegistry.builtIn.byId(AgentIds.claudeCode);

  @override
  AgentStatusReport? statusOf(String sessionId) => AgentStatusReport(
    agentId: AgentIds.claudeCode,
    sessionId: sessionId,
    status: AgentActivityStatus.awaitingApproval,
    source: AgentStatusSource.terminalGrid,
    observedAt: DateTime.utc(2026, 10, 8),
    waiting: AgentWaitKind.approval,
    evidence: evidence,
  );

  @override
  List<String>? screen(String sessionId) => pane.screen;

  @override
  bool press(String sessionId, String keys) => pane.press(keys);

  @override
  Future<AgentQuestionSet?> openQuestion(String sessionId) async => null;

  @override
  void record(DecisionRecord decision) => recorded.add(decision);
}

void main() {
  SessionPromptAnswers answersOver(_Terminals terminals) =>
      SessionPromptAnswers(
        terminals: terminals,
        menuPoll: const Duration(milliseconds: 1),
        menuPatience: const Duration(milliseconds: 60),
      );

  Future<(FakeChecklistPane, _Terminals, String)> open(
    List<String> servers, {
    List<bool>? ticks,
  }) async {
    final pane = FakeChecklistPane(servers, ticks: ticks);
    final terminals = _Terminals(pane);
    final menu = answersOver(terminals).menuOnScreen('s1')!;
    expect(menu.isChecklist, isTrue);
    return (pane, terminals, menu.id);
  }

  test('evidence offers the checklist with its ticks', () async {
    final (_, terminals, _) = await open(['dart', 'marionette']);
    final evidence = await answersOver(terminals).evidence('s1');
    expect(evidence.asking, isTrue);
    expect(evidence.menu!.options, ['dart', 'marionette', 'Enable selected']);
    expect(evidence.menu!.checked, [true, true, null]);
    expect(evidence.approve, isNull, reason: 'Enter would submit every tick');
  });

  test('submitting the ticks as drawn is Down, Down, Enter', () async {
    final (pane, terminals, id) = await open(['dart', 'marionette']);
    final answer = await answersOver(terminals).answer(
      MenuAnswerRequest.checklist(
        sessionId: 's1',
        menuId: id,
        submit: 2,
        ticks: const [true, true],
      ),
    );
    expect(pane.pressed, ['\x1b[B', '\x1b[B', '\r']);
    expect(pane.closedWith, [true, true]);
    expect(answer.answered, 'Enabled dart, marionette');
    expect(terminals.recorded.single.kind, DecisionKind.approvalGranted);
  });

  test('unticking one moves to it, presses Space, then submits', () async {
    final (pane, terminals, id) = await open(['dart', 'marionette']);
    final answer = await answersOver(terminals).answer(
      MenuAnswerRequest.checklist(
        sessionId: 's1',
        menuId: id,
        submit: 2,
        ticks: const [true, false],
      ),
    );
    expect(pane.pressed, ['\x1b[B', ' ', '\x1b[B', '\r']);
    expect(pane.closedWith, [true, false]);
    expect(answer.answered, 'Enabled dart');
  });

  test('a box drawn unticked is ticked, from the submit row upward', () async {
    final (pane, terminals, id) = await open(
      ['alpha', 'beta'],
      ticks: [false, false],
    );
    pane.highlighted = 2;
    await answersOver(terminals).answer(
      MenuAnswerRequest.checklist(
        sessionId: 's1',
        menuId: id,
        submit: 2,
        ticks: const [true, false],
      ),
    );
    expect(pane.pressed, ['\x1b[A', '\x1b[A', ' ', '\x1b[B', '\x1b[B', '\r']);
    expect(pane.closedWith, [true, false]);
  });

  test('unticking every box enables none', () async {
    final (pane, terminals, id) = await open(['dart', 'marionette']);
    final answer = await answersOver(terminals).answer(
      MenuAnswerRequest.checklist(
        sessionId: 's1',
        menuId: id,
        submit: 2,
        ticks: const [false, false],
      ),
    );
    expect(pane.closedWith, [false, false]);
    expect(answer.answered, 'Enabled none');
    expect(terminals.recorded.single.kind, DecisionKind.approachRejected);
  });

  test('reject all is Esc alone', () async {
    final (pane, terminals, id) = await open(['dart', 'marionette']);
    final answer = await answersOver(
      terminals,
    ).answer(MenuAnswerRequest.dismiss(sessionId: 's1', menuId: id));
    expect(pane.pressed, ['\x1b']);
    expect(pane.closedWith, 'rejected');
    expect(answer.answered, 'Rejected all');
    expect(terminals.recorded.single.kind, DecisionKind.approachRejected);
  });

  test(
    'a toggle the pane did not take is said, and Enter never pressed',
    () async {
      final (pane, terminals, id) = await open(['dart', 'marionette']);
      pane.toggles = false;
      await expectLater(
        answersOver(terminals).answer(
          MenuAnswerRequest.checklist(
            sessionId: 's1',
            menuId: id,
            submit: 2,
            ticks: const [false, true],
          ),
        ),
        throwsA(
          isA<SessionPromptRefusal>()
              .having((r) => r.unconfirmed, 'unconfirmed', isTrue)
              .having(
                (r) => r.message,
                'message',
                contains('check the terminal'),
              ),
        ),
      );
      expect(pane.pressed, [' '], reason: 'Space once, never twice');
      expect(pane.closedWith, isNull);
    },
  );

  test('a checklist still on screen after Enter is said', () async {
    final (pane, terminals, id) = await open(['dart', 'marionette']);
    pane.closes = false;
    await expectLater(
      answersOver(terminals).answer(
        MenuAnswerRequest.checklist(
          sessionId: 's1',
          menuId: id,
          submit: 2,
          ticks: const [true, true],
        ),
      ),
      throwsA(
        isA<SessionPromptRefusal>().having(
          (r) => r.message,
          'message',
          contains('still on screen'),
        ),
      ),
    );
  });

  test(
    'a plain choice of "Enable selected" is refused, nothing pressed',
    () async {
      final (pane, terminals, id) = await open(['dart', 'marionette']);
      await expectLater(
        answersOver(
          terminals,
        ).answer(MenuAnswerRequest(sessionId: 's1', menuId: id, option: 2)),
        throwsA(isA<SessionPromptRefusal>()),
      );
      expect(pane.pressed, isEmpty);
    },
  );

  test('approve is refused; deny is the safe Esc', () async {
    final (pane, terminals, _) = await open(['dart', 'marionette']);
    await expectLater(
      answersOver(
        terminals,
      ).answer(const ApprovalAnswerRequest(sessionId: 's1', approve: true)),
      throwsA(isA<SessionPromptRefusal>()),
    );
    expect(pane.pressed, isEmpty);
    await answersOver(
      terminals,
    ).answer(const ApprovalAnswerRequest(sessionId: 's1', approve: false));
    expect(pane.pressed, ['\x1b']);
    expect(pane.closedWith, 'rejected');
  });

  test('ticks and dismiss cross the wire', () {
    final sent = MenuAnswerRequest.checklist(
      sessionId: 's1',
      menuId: 'm',
      submit: 2,
      ticks: const [true, false],
    );
    final read =
        PromptAnswerRequest.fromJson(sent.toJson())! as MenuAnswerRequest;
    expect(read.ticks, [true, false]);
    expect(read.option, 2);
    final dismissed =
        PromptAnswerRequest.fromJson(
              MenuAnswerRequest.dismiss(sessionId: 's1', menuId: 'm').toJson(),
            )!
            as MenuAnswerRequest;
    expect(dismissed.dismiss, isTrue);
  });

  group("a client with no pane answers by the status's quote", () {
    final claude = AgentRegistry.builtIn.byId(AgentIds.claudeCode)!;

    /// The bottom [rows] of [pane]'s screen, blank rows dropped, as the grid
    /// source quotes them: four servers push the heading out of twelve.
    List<String> quote(FakeChecklistPane pane, int rows) {
      final screen = pane.screen!;
      return [
        for (final row in screen.sublist(screen.length - rows))
          if (row.trim().isNotEmpty) row.trimRight(),
      ];
    }

    test(
      'cut short of its heading, it still names the menu on screen',
      () async {
        final (pane, terminals, screenId) = await open(['a', 'b', 'c', 'd']);
        terminals.evidence = quote(pane, 8);
        final quoted = menuQuotedBy(terminals.statusOf('s1'), claude.menus)!;
        expect(
          quoted.prompt,
          isNot(contains('4 new MCP servers found in this project')),
        );
        expect(quoted.id, isNot(screenId), reason: 'the heading is in the id');

        final answer = await answersOver(terminals).answer(
          MenuAnswerRequest.checklist(
            sessionId: 's1',
            menuId: quoted.id,
            submit: 4,
            ticks: const [true, false, true, true],
          ),
        );
        expect(pane.closedWith, [true, false, true, true]);
        expect(answer.answered, 'Enabled a, c, d');
      },
    );

    test('reject all by the quote is Esc alone', () async {
      final (pane, terminals, _) = await open(['dart', 'marionette']);
      terminals.evidence = quote(pane, 6);
      final quoted = menuQuotedBy(terminals.statusOf('s1'), claude.menus)!;
      await answersOver(
        terminals,
      ).answer(MenuAnswerRequest.dismiss(sessionId: 's1', menuId: quoted.id));
      expect(pane.pressed, ['\x1b']);
    });

    test('a quote of other choices names no menu: nothing pressed', () async {
      final (pane, terminals, _) = await open(['dart', 'marionette']);
      terminals.evidence = quote(FakeChecklistPane(['dart', 'other']), 6);
      final quoted = menuQuotedBy(terminals.statusOf('s1'), claude.menus)!;
      await expectLater(
        answersOver(
          terminals,
        ).answer(MenuAnswerRequest.dismiss(sessionId: 's1', menuId: quoted.id)),
        throwsA(
          isA<SessionPromptRefusal>().having((r) => r.stale, 'stale', isTrue),
        ),
      );
      expect(pane.pressed, isEmpty);
    });

    test('a hook message, or no open prompt, quotes no menu', () {
      final report = AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: 's1',
        status: AgentActivityStatus.awaitingApproval,
        source: AgentStatusSource.hook,
        observedAt: DateTime.utc(2026, 10, 17),
        waiting: AgentWaitKind.approval,
        evidence: const ['Claude needs your permission to use Bash'],
      );
      expect(menuQuotedBy(report, claude.menus), isNull);
      final idle = AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: 's1',
        status: AgentActivityStatus.idle,
        source: AgentStatusSource.terminalGrid,
        observedAt: DateTime.utc(2026, 10, 17),
        evidence: FakeChecklistPane(['dart', 'marionette']).screen!,
      );
      expect(menuQuotedBy(idle, claude.menus), isNull);
    });
  });
}
