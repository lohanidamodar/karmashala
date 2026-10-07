import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/app/shell/quick_open/typed_command.dart';
import 'package:karmashala/src/app/shell/quick_open/typed_command_confirm.dart';
import 'package:karmashala/src/app/shell/quick_open/typed_command_history.dart';
import 'package:karmashala/src/app/shell/quick_open/typed_command_runner.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/overview/application/overview_quick_message.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/remote/application/remote_approval_bindings.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_answers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_remote/remote.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fakes.dart';
import '../../../support/fake_data_server.dart';
import '../../../support/fixtures.dart';
import '../../../support/test_machine.dart';

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

/// Records the dashboard's quick message instead of sending it.
class _SpyMessage extends OverviewQuickMessage {
  _SpyMessage(super.ref);

  final sent = <(String, String)>[];

  @override
  Future<QuickMessageOutcome> send(String sessionId, String text) async {
    sent.add((sessionId, text));
    return QuickMessageOutcome.sent;
  }
}

/// **Ctrl+K acts on sessions**: each typed command reaches the action the
/// dashboard itself uses, an ambiguous name runs nothing, and a group asks
/// first, naming the sessions.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Directory prefs;
  late _Recorder recorder;
  late _SpyMessage messages;
  final questions = <RemoteQuestionAnswerRequest>[];
  final now = FixedClock(testTime).nowUtc();

  AgentStatusReport waiting(AgentWaitKind kind, {AgentToolAsk? ask}) =>
      AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: 'cli',
        status: AgentActivityStatus.awaitingApproval,
        observedAt: now,
        source: AgentStatusSource.hook,
        waiting: kind,
        toolAsk: ask,
      );
  final reports = {
    's1': waiting(
      AgentWaitKind.approval,
      ask: AgentToolAsk(
        toolName: 'Bash',
        input: const {'command': 'npm test'},
        at: now,
        cwd: '/src/app',
        options: const [
          AgentToolAskOption(id: 'ok', name: 'Allow', kind: 'allow_once'),
          AgentToolAskOption(id: 'no', name: 'Reject', kind: 'reject_once'),
        ],
      ),
    ),
    's2': waiting(AgentWaitKind.question),
  };
  const question = RemoteQuestion(
    toolUseId: 'toolu_q',
    questions: [
      RemoteQuestionItem(
        question: 'Merge where?',
        options: [
          RemoteQuestionOption(label: 'feat/acp'),
          RemoteQuestionOption(label: 'main'),
        ],
      ),
    ],
  );

  setUp(() async {
    questions.clear();
    prefs = await Directory.systemTemp.createTemp('ks-r48-palette');
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    server.projectRows.insert(project(name: 'Karmashala'));
    server.repositoryRows.insert(repository(name: 'app'));
    server.installationRows.insert(agentInstallation());
    db.server.sessionRows
      ..insert(session(id: 's1', title: 'Fix login redirect'))
      ..insert(session(id: 's2', title: 'Write the release notes'))
      ..insert(session(id: 's3', title: 'Old spike'));
  });
  tearDown(() async {
    try {
      await prefs.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold the prefs file; the OS sweeps temp.
    }
  });

  Future<ProviderContainer> open(
    WidgetTester tester, {
    Size size = const Size(1100, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    recorder = _Recorder();
    final data = await server.override();
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        data,
        overviewPrefsDirectoryProvider.overrideWithValue(() async => prefs),
        sessionStatusLookupProvider.overrideWithValue((id) => reports[id]),
        sessionAnswerableProvider.overrideWithValue((_) => true),
        sessionPromptAnswersProvider.overrideWithValue(recorder),
        chatOpenQuestionProvider.overrideWith(
          (ref, id) async => id == 's2' ? question : null,
        ),
        chatQuestionAnswerProvider.overrideWithValue((request) async {
          questions.add(request);
          return 'ok';
        }),
        overviewQuickMessageProvider.overrideWith(_SpyMessage.new),
      ],
    );
    addTearDown(container.dispose);
    messages = container.read(overviewQuickMessageProvider) as _SpyMessage;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => QuickOpen.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  testWidgets('allow answers the approval by the board\'s own path, and is '
      'never kept to run again', (tester) async {
    await open(tester);

    await type(tester, 'allow fix');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.textContaining('Allow Fix login redirect'), findsOneWidget);
    expect(find.textContaining('npm test'), findsOneWidget);
    expect(find.text('in /src/app'), findsOneWidget);

    await enter(tester);

    final request = recorder.asked.single as ApprovalAnswerRequest;
    expect(request.sessionId, 's1');
    expect(request.approve, isTrue);
    expect(request.optionId, 'ok');
    expect(find.byType(QuickOpen), findsNothing);
    expect(TypedCommandHistory(server.store).list(), isEmpty);
  });

  testWidgets('deny sends the agent\'s own reject option', (tester) async {
    await open(tester);

    await type(tester, 'deny fix-login-redirect');
    await enter(tester);

    final request = recorder.asked.single as ApprovalAnswerRequest;
    expect(request.approve, isFalse);
    expect(request.optionId, 'no');
  });

  testWidgets('answer picks an option by number, once the question is read', (
    tester,
  ) async {
    await open(tester);

    await type(tester, 'answer write 2');
    expect(find.textContaining('— 2 · main'), findsOneWidget);

    await enter(tester);

    expect(questions.single.sessionId, 's2');
    expect(questions.single.toolUseId, 'toolu_q');
    expect(questions.single.answers.single.options, [1]);
  });

  testWidgets('a name that finds several sessions lists them and runs '
      'nothing', (tester) async {
    await open(tester);

    await type(tester, 'message re hello');
    expect(find.textContaining('finds 2 sessions'), findsOneWidget);
    expect(find.text('Fix login redirect'), findsWidgets);
    expect(find.text('Write the release notes'), findsWidgets);

    await enter(tester);

    expect(messages.sent, isEmpty);
    expect(find.byType(QuickOpen), findsOneWidget);
  });

  testWidgets('message reaches the dashboard\'s send', (tester) async {
    await open(tester);

    await type(tester, 'message fix-login-redirect ship it');
    expect(
      find.textContaining(
        RegExp(r'^Message Fix login redirect · .*: "ship it"$'),
      ),
      findsOneWidget,
    );
    await enter(tester);

    expect(messages.sent, [('s1', 'ship it')]);
  });

  testWidgets('open brings the dashboard forward on its board', (tester) async {
    final container = await open(tester);
    container
        .read(overviewPrefsProvider.notifier)
        .setView(OverviewView.timeline);

    await type(tester, 'open old-spike');
    expect(
      find.textContaining(
        RegExp(r'^Open Old spike · .* on the Agent dashboard$'),
      ),
      findsOneWidget,
    );
    await enter(tester);

    expect(container.read(overviewPrefsProvider).view, OverviewView.board);
    // The peek waits for a board this harness never draws; let it give up.
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(find.byType(QuickOpen), findsNothing);
  });

  testWidgets('at phone width the palette previews and runs the same', (
    tester,
  ) async {
    await open(tester, size: const Size(360, 740));

    await type(tester, 'allow fix-login-redirect');
    expect(find.textContaining('Allow Fix login redirect'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await enter(tester);
    expect(recorder.asked, hasLength(1));
  });

  testWidgets('the runner messages and interrupts each of a group', (
    tester,
  ) async {
    final container = await open(tester);
    final said = <String>[];
    final runner = TypedCommandRunner(container, say: said.add);

    await runner.run(const MessageCommand(['s1', 's2'], 'wrap up'));
    expect(messages.sent, [('s1', 'wrap up'), ('s2', 'wrap up')]);
    expect(said.single, 'Sent to 2.');

    said.clear();
    await runner.run(const StopAllCommand(['s1', 's2']));
    // Neither has a live terminal here, and each says so rather than guess.
    expect(said, hasLength(2));
  });

  testWidgets('a group confirm names every session, and Cancel runs '
      'nothing', (tester) async {
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            host = context;
            return const SizedBox();
          },
        ),
      ),
    );
    const confirm = CommandConfirm(
      title: 'Message 2 sessions?',
      names: ['Round 21 · feat/acp', 'Round 22 · main'],
      confirmLabel: 'Send',
    );

    var answer = confirmTypedCommand(host, confirm);
    await tester.pumpAndSettle();
    expect(find.text('Message 2 sessions?'), findsOneWidget);
    expect(find.textContaining('• Round 21 · feat/acp'), findsOneWidget);
    expect(find.textContaining('• Round 22 · main'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);

    answer = confirmTypedCommand(host, confirm);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
  });
}
