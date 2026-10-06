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

const _environments = [
  CommandEnvironment(id: 'windows', token: 'windows', label: 'Windows'),
  CommandEnvironment(
    id: 'wsl:archlinux',
    token: 'archlinux',
    label: 'WSL · archlinux',
  ),
  CommandEnvironment(id: 'ssh:do', token: 'do-box', label: 'SSH · do-box'),
];

const _noTerminal = CommandTerminalTarget(
  refusal:
      'appwrite-ai-workdir lives in WSL · archlinux, which SSH · do-box '
      'cannot reach',
);

final _projects = [
  const CommandProject(
    id: 'p1',
    name: 'appwrite-ai-workdir',
    token: 'appwrite-ai-workdir',
    environmentId: 'wsl:archlinux',
    recencyRank: 3,
    installations: [
      CommandInstallation(id: 'i1', agentId: 'claudeCode'),
      CommandInstallation(id: 'i2', agentId: 'codex'),
    ],
    // Codex ran its last session, so it is the default.
    defaultInstallationId: 'i2',
    branch: 'main',
    terminals: {
      'wsl:archlinux': CommandTerminalTarget(
        profileId: 'wsl:archlinux',
        workingDirectory: '/home/me/appwrite-ai-workdir',
      ),
      'windows': CommandTerminalTarget(
        profileId: 'powershell',
        workingDirectory:
            r'\\wsl.localhost\archlinux\home\me\appwrite-ai-workdir',
      ),
      'ssh:do': _noTerminal,
    },
  ),
  const CommandProject(
    id: 'p2',
    name: 'karmashala',
    token: 'karmashala',
    environmentId: 'windows',
    recencyRank: 0,
    installations: [CommandInstallation(id: 'i3', agentId: 'claudeCode')],
    defaultInstallationId: 'i3',
    terminals: {
      'windows': CommandTerminalTarget(
        profileId: 'powershell',
        workingDirectory: r'C:\src\karmashala',
      ),
      'wsl:archlinux': CommandTerminalTarget(
        profileId: 'wsl:archlinux',
        workingDirectory: '/mnt/c/src/karmashala',
      ),
      'ssh:do': CommandTerminalTarget(
        refusal: 'karmashala lives in Windows, which SSH · do-box cannot reach',
      ),
    },
  ),
  const CommandProject(
    id: 'p3',
    name: 'do-thing',
    token: 'do-thing',
    environmentId: 'ssh:do',
  ),
  const CommandProject(
    id: 'p4',
    name: 'api-server',
    token: 'api-server',
    environmentId: 'windows',
    recencyRank: 5,
    waiting: true,
    installations: [CommandInstallation(id: 'i4', agentId: 'claudeCode')],
    defaultInstallationId: 'i4',
  ),
  const CommandProject(
    id: 'p5',
    name: 'notes',
    token: 'notes',
    environmentId: 'windows',
    installations: [CommandInstallation(id: 'i5', agentId: 'claudeCode')],
    defaultInstallationId: 'i5',
    notGit: true,
  ),
];

const _sessions = [
  CommandSession(
    id: 's1',
    title: 'Fix login redirect',
    token: 'fix-login-redirect',
    projectId: 'p2',
    projectName: 'karmashala',
    agentName: 'Claude Code',
    dot: SessionDot.working,
    ageLabel: 'active 1m ago',
    recencyRank: 0,
    live: true,
    stopRefusal: null,
    endRefusal: null,
  ),
  CommandSession(
    id: 's2',
    title: 'Write release notes',
    token: 'write-release-notes',
    projectId: 'p1',
    projectName: 'appwrite-ai-workdir',
    agentName: 'Codex',
    dot: SessionDot.waiting,
    recencyRank: 3,
    live: true,
    stopRefusal: 'It is asking you something — Esc would answer it.',
    endRefusal: null,
  ),
  CommandSession(
    id: 's3',
    title: 'Old spike',
    token: 'old-spike',
    projectId: 'p2',
    projectName: 'karmashala',
    dot: SessionDot.stopped,
    recencyRank: 7,
    forkRefusal:
        'No conversation id was recorded, so there is nothing to fork.',
  ),
  CommandSession(
    id: 'imp1',
    title: 'Imported chat',
    token: 'imported-chat',
    projectId: 'p1',
    projectName: 'appwrite-ai-workdir',
    imported: true,
    recencyRank: 9,
  ),
];

CommandCatalog catalog({
  CommandWaiting? waiting,
  List<ConversationMatch> Function(String)? search,
}) => CommandCatalog(
  projects: _projects,
  sessions: _sessions,
  environments: _environments,
  agents: _agents,
  oldestWaiting: waiting,
  searchConversations: search,
);

TypedCommand parse(String text, {CommandCatalog? using, int? cursor}) {
  final result = parseTypedCommand(text, using ?? catalog(), cursor: cursor);
  expect(result, isNotNull, reason: '"$text" should be a typed command');
  return result!;
}

List<String> labels(TypedCommand command) => [
  for (final s in command.suggestions) s.label,
];

void main() {
  group('the argument scorer', () {
    test('is a case-insensitive subsequence match', () {
      expect(commandMatchScore('AWD', 'appwrite-ai-workdir'), isNotNull);
      expect(commandMatchScore('xyz', 'appwrite-ai-workdir'), isNull);
      // Order matters: the characters must appear in sequence.
      expect(commandMatchScore('wa', 'aw'), isNull);
    });

    test('rewards a prefix, a word start and a run', () {
      final prefix = commandMatchScore('app', 'appwrite')!;
      final inner = commandMatchScore('app', 'myapp')!;
      expect(prefix, greaterThan(inner));
      // Word starts: `aw` on `ai-workdir` beats `aw` scattered in `rawhide`.
      final words = commandMatchScore('aw', 'ai-workdir')!;
      final scattered = commandMatchScore('aw', 'rawhide')!;
      expect(words, greaterThan(scattered));
    });

    test('ignores separators and case, as every search does', () {
      for (final typed in ['appwrite_ai', 'appwrite.ai', 'appwriteAiWorkdir']) {
        expect(
          commandMatchScore(typed, 'appwrite-ai-workdir'),
          isNotNull,
          reason: typed,
        );
      }
    });

    test('an empty query matches everything, scoring nothing', () {
      expect(commandMatchScore('', 'anything'), 0);
    });
  });

  group('plain search is untouched', () {
    for (final text in [
      'fix login',
      'settings',
      'start',
      'resume',
      'startle the cat',
      'news today',
      'open settings',
      'open ',
      'openterminal x',
      '>start x',
      '#resume x',
      '',
      '   ',
    ]) {
      test('"$text" is not a command', () {
        expect(typedCommandVerbOf(text), isNull);
        expect(parseTypedCommand(text, catalog()), isNull);
      });
    }

    test('a verb needs the space after it', () {
      expect(typedCommandVerbOf('stop'), isNull);
      expect(typedCommandVerbOf('stop '), CommandVerb.stop);
    });
  });

  group('start', () {
    test('an empty argument lists projects, waiting first, then recent', () {
      final command = parse('start ');
      expect(command.pending, CommandArgKind.project);
      expect(command.plan, isNull);
      expect(labels(command), [
        'api-server', // a session is waiting on you
        'karmashala', // most recent
        'appwrite-ai-workdir',
        'do-thing', // no reading: original order
        'notes',
      ]);
      expect(command.suggestions.first.detail, 'waiting on you');
      // The environment is the hint.
      expect(
        command.suggestions
            .firstWhere((s) => s.label == 'appwrite-ai-workdir')
            .hint,
        'WSL · archlinux',
      );
    });

    test('a partial project matches fuzzily and completes to the next '
        'argument', () {
      final command = parse('start awd');
      expect(labels(command), ['appwrite-ai-workdir']);
      expect(command.plan, isNull);
      expect(
        command.suggestions.single.completion,
        'start appwrite-ai-workdir ',
      );
    });

    test('an omitted agent is the project default, spelled out in history', () {
      final command = parse('start appwrite-ai-workdir ');
      final plan = command.plan!;
      expect(plan.runnable, isTrue);
      expect(
        plan.preview,
        'Start Codex in appwrite-ai-workdir · WSL · archlinux · branch main',
      );
      expect(plan.canonical, 'start appwrite-ai-workdir codex');
      final action = plan.action! as StartCommand;
      expect(action.projectId, 'p1');
      expect(action.installationId, 'i2');
      expect(action.worktree, isFalse);
    });

    test('agents: installed only, the default first, the rest refused with '
        'a reason', () {
      final command = parse('start appwrite-ai-workdir ');
      expect(command.pending, CommandArgKind.agent);
      expect(labels(command), ['codex', 'claude', 'antigravity', '--worktree']);
      expect(command.suggestions.first.detail, 'default');
      final antigravity = command.suggestions[2];
      expect(antigravity.enabled, isFalse);
      expect(antigravity.disabledReason, 'not installed in WSL · archlinux');
    });

    test('a named agent is used', () {
      final plan = parse('start appwrite-ai-workdir claude').plan!;
      expect((plan.action! as StartCommand).installationId, 'i1');
      expect(plan.preview, startsWith('Start Claude Code in'));
    });

    test('a partial agent is completed, not run with the default', () {
      final command = parse('start appwrite-ai-workdir cl');
      expect(command.plan, isNull);
      expect(labels(command), ['claude']);
      expect(
        command.suggestions.single.completion,
        'start appwrite-ai-workdir claude ',
      );
    });

    test('"start session …" and --worktree read as English', () {
      final plan = parse(
        'start session appwrite-ai-workdir claude --worktree',
      ).plan!;
      expect((plan.action! as StartCommand).worktree, isTrue);
      expect(plan.preview, endsWith('· in a new worktree'));
      expect(plan.canonical, 'start appwrite-ai-workdir claude --worktree');
    });

    test('the aliases mean start', () {
      expect(labels(parse('s karm')), ['karmashala']);
      expect(labels(parse('new karm')), ['karmashala']);
      expect(parse('new karm').verb, CommandVerb.start);
    });

    test('an environment with no agent is refused, and says so', () {
      final command = parse('start do-thing ');
      expect(command.plan!.runnable, isFalse);
      expect(command.plan!.refusal, 'No agent is installed in SSH · do-box.');
      expect(
        command.suggestions.where((s) => s.kind == CommandArgKind.agent),
        everyElement(predicate<CommandSuggestion>((s) => !s.enabled)),
      );
    });

    test('an agent not installed there is refused', () {
      final plan = parse('start appwrite-ai-workdir antigravity ').plan!;
      expect(plan.runnable, isFalse);
      expect(plan.action, isNull);
      expect(plan.refusal, 'Antigravity is not installed in WSL · archlinux.');
    });

    test('a project with no git gets no worktree', () {
      final worktree = parse(
        'start notes ',
      ).suggestions.firstWhere((s) => s.label == '--worktree');
      expect(worktree.enabled, isFalse);
      expect(worktree.disabledReason, contains('not a Git repository'));
      final plan = parse('start notes --worktree').plan!;
      expect(plan.runnable, isFalse);
      expect(plan.refusal, contains('has no worktrees'));
    });

    test('a committed name that matches nothing is an error, not a guess', () {
      final command = parse('start nope ');
      expect(command.error, 'No project called "nope".');
      expect(command.plan, isNull);
      expect(parse('start karmashala --force ').error, contains('--worktree'));
    });

    test('only the text before the cursor is completed', () {
      final command = parse('start karm trailing', cursor: 10);
      expect(labels(command), ['karmashala']);
    });
  });

  group('resume', () {
    test('lists sessions waiting first, then recent, then projects', () {
      final command = parse('resume ');
      final sessions = [
        for (final s in command.suggestions)
          if (s.kind == CommandArgKind.session) s.label,
      ];
      expect(sessions, [
        'Write release notes',
        'Fix login redirect',
        'Old spike',
        'Imported chat',
      ]);
      expect(command.suggestions.first.dot, SessionDot.waiting);
      expect(command.suggestions.first.hint, 'appwrite-ai-workdir · Codex');
      expect(
        command.suggestions.where((s) => s.kind == CommandArgKind.project),
        isNotEmpty,
      );
    });

    test('a project expands to its own sessions', () {
      final command = parse('resume appwrite-ai-workdir ');
      expect(labels(command), ['Write release notes', 'Imported chat']);
      expect(
        command.suggestions.first.completion,
        'resume appwrite-ai-workdir write-release-notes ',
      );
    });

    test('a session resolves to the session jump', () {
      final plan = parse('resume fix-login-redirect').plan!;
      final action = plan.action! as ResumeCommand;
      expect(action.sessionId, 's1');
      expect(action.imported, isFalse);
      // It is running, so this brings it back rather than resuming.
      expect(plan.preview, startsWith('Go to "Fix login redirect"'));
      expect(
        parse('resume imported-chat ').plan!.action,
        isA<ResumeCommand>().having((a) => a.imported, 'imported', isTrue),
      );
    });

    test('what was said finds a session no title matches', () {
      final command = parse(
        'resume limiter',
        using: catalog(
          search: (query) => [(sessionId: 's3', excerpt: 'the rate limiter')],
        ),
      );
      final said = command.suggestions.single;
      expect(said.label, 'Old spike');
      expect(said.hint, 'said: the rate limiter');
    });
  });

  group('open terminal', () {
    test('open t… is on its way to terminal', () {
      final command = parse('open t');
      expect(labels(command), ['terminal']);
      expect(command.suggestions.single.completion, 'open terminal ');
    });

    test('defaults to where the project lives', () {
      final plan = parse('term karmashala ').plan!;
      final action = plan.action! as OpenTerminalCommand;
      expect(action.environmentId, 'windows');
      expect(action.workingDirectory, r'C:\src\karmashala');
      expect(
        plan.preview,
        r'Open a terminal in karmashala · Windows · C:\src\karmashala',
      );
      expect(plan.canonical, 'open terminal karmashala windows');
    });

    test('every environment is offered; one that cannot reach it says why', () {
      final command = parse('open terminal karmashala ');
      expect(labels(command), ['windows', 'archlinux', 'do-box']);
      expect(command.suggestions.first.detail, 'where it lives');
      final doBox = command.suggestions.last;
      expect(doBox.enabled, isFalse);
      expect(doBox.disabledReason, contains('cannot reach'));
      final plan = parse('open terminal karmashala archlinux').plan!;
      expect(
        (plan.action! as OpenTerminalCommand).workingDirectory,
        '/mnt/c/src/karmashala',
      );
      expect(parse('open terminal karmashala do-box').plan!.runnable, isFalse);
    });
  });

  group('answer', () {
    test('goes to the oldest waiting permission', () {
      final plan = parse(
        'answer ',
        using: catalog(
          waiting: const CommandWaiting(
            itemId: 'needsApproval:x',
            sessionId: 's2',
            title: 'Write release notes',
            detail: 'Allow Bash(rm -rf build)?',
          ),
        ),
      ).plan!;
      expect(plan.runnable, isTrue);
      expect((plan.action! as AnswerCommand).itemId, 'needsApproval:x');
      expect(plan.preview, contains('Allow Bash(rm -rf build)?'));
    });

    test('with nothing waiting it is refused, not hidden', () {
      final plan = parse('answer ').plan!;
      expect(plan.runnable, isFalse);
      expect(plan.refusal, 'Nothing is waiting on you.');
      expect(parse('answer now').error, isNotNull);
    });
  });

  group('stop, fork and end', () {
    test('stop lists native sessions, usable first, refusals with reasons', () {
      final command = parse('stop ');
      expect(labels(command), [
        'Fix login redirect',
        'Write release notes',
        'Old spike',
      ]);
      expect(command.suggestions.first.enabled, isTrue);
      expect(
        command.suggestions[1].disabledReason,
        contains('Esc would answer it'),
      );
      // An imported session is not ours to interrupt.
      expect(labels(command), isNot(contains('Imported chat')));
      expect(
        parse('stop fix-login-redirect ').plan!.action,
        isA<StopCommand>().having((a) => a.sessionId, 'id', 's1'),
      );
    });

    test('end and fork carry their own refusals', () {
      final end = parse('end old-spike ').plan!;
      expect(end.runnable, isFalse);
      expect(end.refusal, 'Not running, so there is nothing to end.');
      expect(parse('end fix-login-redirect').plan!.action, isA<EndCommand>());
      final fork = parse('fork old-spike').plan!;
      expect(fork.runnable, isFalse);
      expect(fork.refusal, contains('nothing to fork'));
      expect(
        parse('fork write-release-notes').plan!.action,
        isA<ForkCommand>(),
      );
      expect(parse('stop imported-chat ').error, isNotNull);
    });
  });

  group('tokens', () {
    test('a title becomes one argument', () {
      expect(commandSlug('Fix: the login/redirect!'), 'fix-the-login-redirect');
      expect(commandProjectToken('My App'), 'My-App');
    });

    test('duplicates are told apart by id', () {
      final tokens = uniqueTokens([
        (id: 'abcdef', token: 'work'),
        (id: 'ghijkl', token: 'Work'),
        (id: 'mnop', token: 'other'),
      ]);
      expect(tokens, {
        'abcdef': 'work-abcd',
        'ghijkl': 'Work-ghij',
        'mnop': 'other',
      });
    });
  });
}
