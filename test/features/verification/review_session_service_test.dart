import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/discovery.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/verification/application/review_session_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../fanout/fanout_harness.dart';
import '../terminal/fake_instance.dart';

/// The argv the reviewer's pane was actually launched with — the only place
/// the brief can be observed leaving the app.
String promptSentTo(Harness h, String paneId) {
  final instance =
      h.container
              .read(terminalSessionsControllerProvider.notifier)
              .instanceFor(paneId)!
          as FakeTerminalInstance;
  return instance.agentLaunch!.arguments.join('\n');
}

void main() {
  late Harness h;

  setUp(
    () => h = harness(
      git: (request) {
        final argv = request.arguments.join(' ');
        if (argv.contains('diff') && !argv.contains('--staged')) {
          return const CommandResult(
            exitCode: 0,
            stdout: 'diff --git a/x.dart b/x.dart\n+  final x = 1;\n',
            stderr: '',
          );
        }
        if (argv.contains('rev-parse --abbrev-ref')) {
          return const CommandResult(
            exitCode: 0,
            stdout: 'work/thing\n',
            stderr: '',
          );
        }
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      },
    ),
  );
  tearDown(() {
    h.container.dispose();
    h.db.close();
  });

  ReviewSessionService service() =>
      h.container.read(reviewSessionServiceProvider);

  /// A session doing the work, run by [installation].
  Future<String> work({
    AgentInstallation? installation,
    bool worktree = true,
  }) async {
    final launched = await h.container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: installation ?? roverInstall,
            title: 'Fix the parser',
            purpose: SessionPurpose.newSession,
            useWorktree: worktree,
          ),
        );
    return launched.session.id;
  }

  group('who may review', () {
    test('every other installation is offered, its own never is', () async {
      final offer = service().offerFor(await work());
      expect(offer.isPossible, isTrue);
      expect(
        offer.targets.map((t) => t.installation.id),
        isNot(contains(roverInstall.id)),
      );
      expect(
        offer.targets.map((t) => t.installation.id),
        containsAll([flakyInstall.id, secondRoverInstall.id]),
      );
    });

    test('a second installation of the same agent is marked as one', () async {
      final offer = service().offerFor(await work());
      final sameAgent = offer.targets.firstWhere(
        (t) => t.installation.id == secondRoverInstall.id,
      );
      final otherAgent = offer.targets.firstWhere(
        (t) => t.installation.id == flakyInstall.id,
      );
      expect(sameAgent.isSameAgent, isTrue);
      expect(otherAgent.isSameAgent, isFalse);
    });

    test('the only installed agent cannot review itself', () async {
      final sessionId = await work();
      AgentInstallationDao(h.db)
        ..delete(flakyInstall.id)
        ..delete(secondRoverInstall.id);
      final offer = service().offerFor(sessionId);
      expect(offer.isPossible, isFalse);
      expect(offer.targets, isEmpty);
      expect(offer.refusal, isNotNull);
      expect(offer.refusal, contains('Rover CLI'));
      expect(offer.refusal, contains('Discover agents'));
    });

    test('the spawn-depth cap refuses in its own words', () async {
      // A review is a spawn, so it sits under the same cap. Built by
      // launching the chain rather than by writing parent ids, so the depth
      // walked here is the one a real launch would produce.
      var parent = await work();
      for (var level = 0; level < 2; level++) {
        final child = await h.container
            .read(sessionLauncherProvider)
            .launch(
              SessionLaunchRequest(
                repository: repository(),
                installation: roverInstall,
                title: 'Level $level',
                purpose: SessionPurpose.newSession,
                parentSessionId: parent,
              ),
            );
        parent = child.session.id;
      }
      final offer = service().offerFor(parent);
      expect(offer.isPossible, isFalse);
      expect(offer.refusal, contains('levels deep'));
    });

    test('a session that is gone is refused, not crashed into', () {
      final offer = service().offerFor('no-such-session');
      expect(offer.isPossible, isFalse);
      expect(offer.refusal, isNotNull);
    });

    test('every target carries the capped review permission', () async {
      final offer = service().offerFor(await work());
      for (final target in offer.targets) {
        expect(target.permission.selection, askSelection);
        expect(target.permission.summary, contains(target.agentName));
      }
    });
  });

  group('starting a review', () {
    test('produces an ordinary session row, spawned from the work', () async {
      final subject = await work();
      final launched = await service().startReview(
        sessionId: subject,
        targetInstallationId: flakyInstall.id,
      );
      final row = SessionDao(h.db).getById(launched.session.id)!;
      expect(row.parentSessionId, subject);
      expect(row.parentLink, SessionLink.spawn);
      expect(row.agentInstallationId, flakyInstall.id);
      expect(row.permissionMode, askStored);
      expect(row.title, contains('Fix the parser'));
    });

    test('runs in the same worktree as the work it reviews', () async {
      final subject = await work();
      final subjectRow = SessionDao(h.db).getById(subject)!;
      final launched = await service().startReview(
        sessionId: subject,
        targetInstallationId: flakyInstall.id,
      );
      expect(launched.session.worktree, subjectRow.worktree);
    });

    test('a session cannot be sent to review itself', () async {
      final subject = await work();
      await expectLater(
        service().startReview(
          sessionId: subject,
          targetInstallationId: roverInstall.id,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('the brief names the work, the claim and the verdict calls', () async {
      final subject = await work();
      final brief = await service().buildBrief(
        sessionId: subject,
        targetAgentName: 'Flaky CLI',
        claim: 'The parser now accepts trailing commas.',
      );
      final text = brief.render();
      expect(text, contains('Rover CLI'));
      expect(text, contains('Flaky CLI'));
      expect(text, contains('sessionId: "$subject"'));
      expect(text, contains('The parser now accepts trailing commas.'));
      expect(text, contains('verification_finish'));
      expect(text, contains('final x = 1;'));
    });

    test('the brief is what the reviewer is actually launched with', () async {
      final subject = await work();
      final launched = await service().startReview(
        sessionId: subject,
        targetInstallationId: flakyInstall.id,
        claim: 'The parser now accepts trailing commas.',
      );
      final prompt = promptSentTo(h, launched.paneId!);
      expect(prompt, contains('Review this change'));
      expect(prompt, contains('sessionId: "$subject"'));
      expect(prompt, contains('The parser now accepts trailing commas.'));
    });

    test('a claim nobody wrote down reads as not recorded', () async {
      final brief = await service().buildBrief(
        sessionId: await work(),
        targetAgentName: 'Flaky CLI',
      );
      expect(brief.claim, isNull);
      expect(brief.render(), contains('Not recorded'));
    });
  });
}
