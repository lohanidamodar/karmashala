import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/github/application/pull_request_context_service.dart';
import 'package:karmashala_git/pull_request_context.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';
import 'package:riverpod/riverpod.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// A long paste collapses in the agent's own transcript, so the only place
/// that can answer "what was it actually told?" is this record. What it keeps
/// has to be the prompt itself — not a summary, not a rebuild of it.
class _RecordingActions extends SessionActions {
  _RecordingActions(super.ref, {this.fail = false});

  final bool fail;
  final sent = <String>[];

  @override
  Future<void> continueSession(String sessionId, String text) async {
    if (fail) throw StateError('the pane is gone');
    sent.add(text);
  }
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late _RecordingActions actions;

  void build({bool failSend = false}) {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        sessionActionsProvider.overrideWith((ref) {
          actions = _RecordingActions(ref, fail: failSend);
          return actions;
        }),
      ],
    );
    // Built eagerly so `actions` is bound before a test reads it.
    container.read(sessionActionsProvider);
  }

  setUp(build);
  tearDown(() {
    container.dispose();
    db.close();
  });

  PullRequestContextService service() =>
      container.read(pullRequestContextServiceProvider);

  Future<void> send({
    String prompt = 'the exact text\nover two lines',
    Set<PullRequestContextPart> parts = const {
      PullRequestContextPart.reference,
    },
  }) => service().send(
    sessionId: 's1',
    prompt: prompt,
    parts: parts,
    pullRequestNumber: 42,
  );

  test('sends the prompt it was given, unchanged', () async {
    await send();
    expect(actions.sent.single, 'the exact text\nover two lines');
  });

  test('keeps the prompt verbatim, not a summary of it', () async {
    await send();
    final card = service().sentIn('s1').single;
    expect(card.prompt, 'the exact text\nover two lines');
    expect(card.pullRequestNumber, 42);
    expect(card.at, testTime);
  });

  test(
    'records which parts went, so what was left out is visible too',
    () async {
      await send(
        parts: {
          PullRequestContextPart.reference,
          PullRequestContextPart.checks,
        },
      );
      expect(service().sentIn('s1').single.parts, ['reference', 'checks']);
    },
  );

  test('a send that failed is still recorded', () async {
    // The one case worth investigating later must not be the one case with
    // no trace of what was attempted.
    build(failSend: true);
    await expectLater(send(), throwsA(isA<StateError>()));
    expect(service().sentIn('s1'), hasLength(1));
  });

  test('cards come back newest first', () async {
    await send(prompt: 'first');
    await send(prompt: 'second');
    expect(service().sentIn('s1').map((c) => c.prompt), ['second', 'first']);
  });

  test('a session with nothing attached has nothing to show', () {
    expect(service().sentIn('s1'), isEmpty);
  });
}
