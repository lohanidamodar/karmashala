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
}
