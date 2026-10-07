import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/typed_command.dart';

const _agents = [
  CommandAgent(
    agentId: 'claudeCode',
    token: 'claude',
    displayName: 'Claude Code',
  ),
  CommandAgent(agentId: 'codex', token: 'codex', displayName: 'Codex'),
  CommandAgent(
    agentId: 'antigravity',
    token: 'antigravity',
    displayName: 'Antigravity',
  ),
];

const _projects = [
  CommandProject(
    id: 'p1',
    name: 'karmashala',
    token: 'karmashala',
    environmentId: 'windows',
    installations: [
      CommandInstallation(id: 'i1', agentId: 'claudeCode'),
      CommandInstallation(id: 'i2', agentId: 'codex'),
    ],
    defaultInstallationId: 'i1',
  ),
  CommandProject(
    id: 'p2',
    name: 'beej',
    token: 'beej',
    environmentId: 'windows',
    installations: [CommandInstallation(id: 'i3', agentId: 'claudeCode')],
  ),
];

const _approval = CommandApproval(
  subject: 'flutter test',
  folder: '/src/ks',
  toolName: 'Bash',
);

const _sessions = [
  CommandSession(
    id: 'r21',
    title: 'Round 21',
    token: 'round-21',
    projectId: 'p1',
    projectName: 'karmashala',
    branch: 'feat/acp',
    dot: SessionDot.waiting,
    live: true,
    question: CommandQuestion(
      toolUseId: 't1',
      options: ['Yes, proceed', 'No', 'Explain more'],
    ),
  ),
  CommandSession(
    id: 'r22',
    title: 'Round 22 deploy',
    token: 'round-22-deploy',
    projectId: 'p1',
    projectName: 'karmashala',
    dot: SessionDot.waiting,
    live: true,
    approval: _approval,
  ),
  CommandSession(
    id: 'r23',
    title: 'Round 23 deploy',
    token: 'round-23-deploy',
    projectId: 'p1',
    projectName: 'karmashala',
    dot: SessionDot.waiting,
    live: true,
    approval: CommandApproval(
      subject: 'rm -rf build',
      folder: '/src/ks',
      denyRefusal: 'This prompt names no way to decline.',
    ),
  ),
  CommandSession(
    id: 'w1',
    title: 'Fix login',
    token: 'fix-login',
    projectId: 'p1',
    projectName: 'karmashala',
    dot: SessionDot.working,
    live: true,
    stopRefusal: null,
    archiveRefusal: 'Still running — end it first.',
  ),
  CommandSession(
    id: 'w2',
    title: 'Store screenshots',
    token: 'store-screenshots',
    projectId: 'p2',
    projectName: 'beej',
    dot: SessionDot.working,
    live: true,
    stopRefusal: null,
    archiveRefusal: 'Still running — end it first.',
  ),
  CommandSession(
    id: 'old',
    title: 'Old spike',
    token: 'old-spike',
    projectId: 'p2',
    projectName: 'beej',
    dot: SessionDot.stopped,
    archiveRefusal: null,
  ),
  CommandSession(
    id: 'q2',
    title: 'Two questions',
    token: 'two-questions',
    projectId: 'p2',
    projectName: 'beej',
    dot: SessionDot.waiting,
    live: true,
    question: CommandQuestion(
      toolUseId: 't2',
      options: ['A', 'B'],
      refusal: 'It asks 2 questions — answer them in its view.',
    ),
  ),
];

const _catalog = CommandCatalog(
  projects: _projects,
  sessions: _sessions,
  agents: _agents,
);

TypedCommand parse(String text) {
  final result = parseTypedCommand(text, _catalog);
  expect(result, isNotNull, reason: '"$text" should be a typed command');
  return result!;
}

CommandPlan plan(String text) {
  final command = parse(text);
  expect(command.plan, isNotNull, reason: '"$text" should have a plan');
  return command.plan!;
}

void main() {
  group('answer', () {
    test('by number, previewed before it runs', () {
      final p = plan('answer round-21 2');
      expect(p.preview, 'Answer Round 21 · feat/acp — 2 · No');
      final action = p.action! as AnswerQuestionCommand;
      expect(action.sessionId, 'r21');
      expect(action.toolUseId, 't1');
      expect(action.option, 1);
      // Never kept: a later question has other options.
      expect(p.canonical, isEmpty);
    });

    test('by label, and the session by words that find only it', () {
      expect(
        (plan('answer round-21 explain').action! as AnswerQuestionCommand)
            .option,
        2,
      );
      expect(
        (plan('answer 21 yes, proceed').action! as AnswerQuestionCommand)
            .option,
        0,
      );
    });

    test('with no option, the options are listed to complete', () {
      final command = parse('answer round-21 ');
      expect(command.pending, CommandArgKind.option);
      expect(
        [for (final s in command.suggestions) s.label],
        ['1 · Yes, proceed', '2 · No', '3 · Explain more'],
      );
      expect(command.suggestions.first.completion, 'answer round-21 1 ');
    });

    test('an option out of range or unknown is said, not guessed', () {
      expect(parse('answer round-21 9').error, contains('1 to 3'));
      final unknown = parse('answer round-21 maybe');
      expect(unknown.error, contains('No option "maybe"'));
      expect(unknown.plan, isNull);
    });

    test('a command approval is not a question; several questions are '
        'refused with why', () {
      expect(
        plan('answer round-22-deploy 1').refusal,
        contains('allow or deny'),
      );
      expect(plan('answer two-questions 1').refusal, contains('2 questions'));
    });

    test('bare answer still goes to the oldest waiting permission', () {
      expect(plan('answer ').refusal, 'Nothing is waiting on you.');
    });
  });

  group('ambiguity', () {
    test('a name that finds several sessions lists them and plans nothing', () {
      final command = parse('allow deploy ');
      expect(command.plan, isNull);
      expect(command.error, '"deploy" finds 2 sessions — pick one.');
      expect(
        [for (final s in command.suggestions) s.label],
        ['Round 22 deploy', 'Round 23 deploy'],
      );
      expect(command.suggestions.first.completion, 'allow round-22-deploy ');
    });

    test('the candidates keep what was typed after the name', () {
      final command = parse('message round hello there');
      expect(command.plan, isNull);
      expect(
        command.suggestions.first.completion,
        'message round-21 hello there',
      );
    });

    test('a name that finds nothing is an error', () {
      expect(
        parse('archive nothing-here ').error,
        'No session called '
        '"nothing-here".',
      );
    });
  });

  group('allow and deny', () {
    test('allow names the command and where it runs', () {
      final p = plan('allow round-22-deploy');
      expect(p.preview, 'Allow Round 22 deploy · karmashala — flutter test');
      expect(p.note, 'in /src/ks');
      expect(
        p.action,
        isA<ApprovalCommand>().having((a) => a.allow, 'allow', isTrue),
      );
      expect(p.canonical, isEmpty);
    });

    test('a prompt with no way to decline is refused with why', () {
      final p = plan('deny round-23-deploy');
      expect(p.runnable, isFalse);
      expect(p.refusal, 'This prompt names no way to decline.');
    });

    test('a session asking a question has no command to allow', () {
      expect(
        plan('allow round-21').refusal,
        'Not waiting on a command approval',
      );
    });
  });

  group('message, stop, resume, archive, open', () {
    test('message one session', () {
      final p = plan('message fix-login run the tests again');
      final action = p.action! as MessageCommand;
      expect(action.sessionIds, ['w1']);
      expect(action.text, 'run the tests again');
      expect(p.confirm, isNull);
      expect(
        plan('message fix-login ').refusal,
        'Type the message after its name.',
      );
    });

    test('stop one session still presses Esc', () {
      expect(plan('stop fix-login').action, isA<StopCommand>());
    });

    test('resume a stopped session in the background, with words', () {
      final p = plan('resume old-spike pick up where you left off');
      final action = p.action! as BackgroundResumeCommand;
      expect(action.sessionId, 'old');
      expect(action.message, 'pick up where you left off');
      expect(p.preview, startsWith('Resume "Old spike" in the background'));
      expect(plan('resume fix-login hello').refusal, contains('message'));
    });

    test('archive one that has ended; a running one is refused', () {
      expect(plan('archive old-spike').action, isA<ArchiveCommand>());
      expect(
        plan('archive fix-login').refusal,
        'Still running — end it first.',
      );
    });

    test('open and peek show a session on the dashboard', () {
      final p = plan('open round-21');
      expect(p.preview, 'Open Round 21 · feat/acp on the Agent dashboard');
      expect(p.action, isA<PeekCommand>());
      expect(plan('peek old ').action, isA<PeekCommand>());
      // Words no session holds stay a search.
      expect(parseTypedCommand('open settings', _catalog), isNull);
      expect(
        parseTypedCommand('open terminal', _catalog)?.verb,
        CommandVerb.openTerminal,
      );
    });
  });

  group('new <agent> in <project>', () {
    test('starts kept on the dashboard with what follows as the prompt', () {
      final p = plan('new codex in karmashala fix the login bug');
      final action = p.action! as StartCommand;
      expect(action.projectId, 'p1');
      expect(action.installationId, 'i2');
      expect(action.keepHere, isTrue);
      expect(action.firstMessage, 'fix the login bug');
      expect(
        p.preview,
        'New Codex session in karmashala, on the Agent '
        'dashboard',
      );
    });

    test('a colon in the prompt is part of it, and one after the project '
        'only marks where it starts', () {
      String? said(String text) =>
          (plan(text).action! as StartCommand).firstMessage;
      expect(
        said('new codex in karmashala run this command: git log -1'),
        'run this command: git log -1',
      );
      expect(said('new codex in karmashala: fix it'), 'fix it');
      expect(said('new codex in karmashala : fix: it'), 'fix: it');
    });

    test('the project completes, and an agent not installed is refused', () {
      final command = parse('new claude in kar');
      expect(command.pending, CommandArgKind.project);
      expect(command.suggestions.first.completion, 'new claude in karmashala ');
      expect(plan('new codex in beej ').refusal, contains('not installed'));
    });
  });

  group('groups', () {
    test('message all working asks first, naming each', () {
      final p = plan('message all working wrap up');
      final action = p.action! as MessageCommand;
      expect(action.sessionIds, ['w1', 'w2']);
      expect(action.text, 'wrap up');
      expect(p.confirm!.names, [
        'Fix login · karmashala',
        'Store screenshots · '
            'beej',
      ]);
      expect(p.confirm!.title, 'Message 2 sessions?');
    });

    test('stop all in a project interrupts only those mid-turn', () {
      final p = plan('stop all in karmashala');
      expect((p.action! as StopAllCommand).sessionIds, ['w1']);
      expect(p.confirm!.names, ['Fix login · karmashala']);
      expect(p.canonical, 'stop all in karmashala');
    });

    test('all with nothing to narrow it is refused', () {
      expect(plan('message all hello').refusal, startsWith('Say which'));
    });

    test('the qualifiers complete', () {
      final command = parse('message all wor');
      expect([for (final s in command.suggestions) s.label], ['working']);
      expect(command.suggestions.single.completion, 'message all working ');
      expect(parse('stop all in ').pending, CommandArgKind.project);
    });

    test('a group with no one in it is refused, not run empty', () {
      expect(
        plan('message all idle hi').refusal,
        'No idle sessions to '
        'message.',
      );
    });
  });
}
