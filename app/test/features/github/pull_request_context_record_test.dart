import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/github/application/pull_request_context_service.dart';
import 'package:karmashala_git/pull_request_context.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:riverpod/riverpod.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';

/// A long paste collapses in the agent's own transcript, so the only place
/// that can answer "what was it actually told?" is this record. What it keeps
/// has to be the prompt itself — not a summary, not a rebuild of it.
class _RecordingActions extends SessionActions {
  _RecordingActions(super.ref, {this.fail = false});

  final bool fail;
  final sent = <String>[];

  @override
  Future<void> continueSession(
    String sessionId,
    String text, {
    String? requestId,
  }) async {
    if (fail) throw StateError('the pane is gone');
    sent.add(text);
  }
}

void main() {
  late ProviderContainer container;
  late _RecordingActions actions;

  Future<void> build({bool failSend = false}) async {
    final server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    server.sessionRows.insert(session());
    container = ProviderContainer(
      overrides: [
        await server.override(),
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
    final card = (await service().sentIn('s1')).single;
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
      expect((await service().sentIn('s1')).single.parts, [
        'reference',
        'checks',
      ]);
    },
  );

  test('a send that failed is still recorded', () async {
    // The one case worth investigating later must not be the one case with
    // no trace of what was attempted.
    await build(failSend: true);
    await expectLater(send(), throwsA(isA<StateError>()));
    expect(await service().sentIn('s1'), hasLength(1));
  });

  test('cards come back newest first', () async {
    await send(prompt: 'first');
    await send(prompt: 'second');
    expect((await service().sentIn('s1')).map((c) => c.prompt), [
      'second',
      'first',
    ]);
  });

  test('a session with nothing attached has nothing to show', () async {
    expect(await service().sentIn('s1'), isEmpty);
  });
}
