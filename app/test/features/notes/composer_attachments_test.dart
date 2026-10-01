import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/notes/application/composer_draft.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// *Attach to chat* from an open file: the file is offered to a session the
/// way a note is — its path typed at the prompt when the terminal is the face
/// on screen, else queued for the composer as an attachment — and always in
/// the spelling the session's **agent** reads.
void main() {
  const shot = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\demo\shot.png',
  );

  group('ComposerAttachments', () {
    test('queues per session, in order, and take leaves nothing behind', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final queue = container.read(composerAttachmentsProvider.notifier);
      const second = EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\demo\notes.md',
      );

      queue.queue('s1', shot);
      queue.queue('s1', second);
      queue.queue('s2', second);

      expect(queue.take('s1'), [shot, second]);
      expect(queue.take('s1'), isNull, reason: 'taken means gone');
      expect(container.read(composerAttachmentsProvider), {
        's2': [second],
      });
    });

    test('the same file twice is one attachment', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final queue = container.read(composerAttachmentsProvider.notifier);

      queue.queue('s1', shot);
      queue.queue('s1', shot);

      expect(queue.take('s1'), [shot]);
    });

    test('the same text in two environments is two files', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final queue = container.read(composerAttachmentsProvider.notifier);
      const elsewhere = EnvironmentPath(
        environmentId: 'wsl:Ubuntu',
        path: r'C:\src\demo\shot.png',
      );

      queue.queue('s1', shot);
      queue.queue('s1', elsewhere);

      expect(queue.take('s1'), hasLength(2));
    });
  });

  test('an unreachable file says it was not attached', () {
    expect(
      sessionOfferMessage(SessionOfferOutcome.outOfReach, 'Resize'),
      'Not attached: Resize’s agent cannot reach that file from where it '
      'runs.',
    );
  });

  /// No pane: the routing never reaches the terminals, so a plain container
  /// over the fake server is enough to pin where the file goes and how it is
  /// spelled.
  group('offerFileToSessionWith, with no pane showing the session', () {
    Future<ProviderContainer> containerWith({
      required String agentEnvironmentId,
    }) async {
      final server = FakeDataServer(clock: () => testTime)
        ..environmentRows.upsert(windowsEnv())
        ..environmentRows.upsert(wslEnv())
        ..environmentRows.upsert(sshEnvFixture())
        ..projectRows.insert(project())
        ..repositoryRows.insert(repository());
      server.installationRows.insert(
        agentInstallation(environmentId: agentEnvironmentId),
      );
      server.sessionRows.insert(session(title: 'Resize'));
      final container = ProviderContainer(
        overrides: [
          await server.override(),
          clockProvider.overrideWithValue(FixedClock(testTime)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a file in the agent\'s own environment is queued as it is', () async {
      final container = await containerWith(agentEnvironmentId: 'windows');

      final outcome = offerFileToSessionWith(
        container.read,
        sessionId: 's1',
        file: shot,
      );

      expect(outcome, SessionOfferOutcome.waitingForAPane);
      expect(container.read(composerAttachmentsProvider)['s1'], [shot]);
      expect(
        container.read(composerDraftProvider),
        isEmpty,
        reason: 'a file is an attachment, not words in the box',
      );
    });

    test('a Windows file offered to a WSL agent is queued as /mnt/c', () async {
      final container = await containerWith(agentEnvironmentId: 'wsl:Ubuntu');

      offerFileToSessionWith(container.read, sessionId: 's1', file: shot);

      expect(container.read(composerAttachmentsProvider)['s1'], const [
        EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/mnt/c/src/demo/shot.png',
        ),
      ]);
    });

    test('a file on an SSH host is out of reach of a local agent, and is '
        'not queued', () async {
      final container = await containerWith(agentEnvironmentId: 'windows');

      final outcome = offerFileToSessionWith(
        container.read,
        sessionId: 's1',
        file: const EnvironmentPath(
          environmentId: 'ssh:h1',
          path: '/home/dlohani/shot.png',
        ),
      );

      expect(outcome, SessionOfferOutcome.outOfReach);
      expect(container.read(composerAttachmentsProvider), isEmpty);
    });

    test(
      'a file on the SSH host the agent runs on is queued as it is',
      () async {
        final container = await containerWith(agentEnvironmentId: 'ssh:h1');
        const there = EnvironmentPath(
          environmentId: 'ssh:h1',
          path: '/home/dlohani/shot.png',
        );

        offerFileToSessionWith(container.read, sessionId: 's1', file: there);

        expect(container.read(composerAttachmentsProvider)['s1'], [there]);
      },
    );
  });

  /// With a pane: the face on screen decides, exactly as for a note.
  group('offerFileToSession, with the session in a tab', () {
    late TestMachine db;
    late ProviderContainer container;

    Future<String> runSessionInATab(WidgetTester tester) async {
      db = TestMachine();
      final server = FakeDataServer(clock: () => testTime).runsOn(db)
        ..environmentRows.upsert(windowsEnv())
        ..projectRows.insert(project())
        ..repositoryRows.insert(repository());
      server.installationRows.insert(agentInstallation());
      container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(machine: db),
          await server.override(),
          clockProvider.overrideWithValue(FixedClock(testTime)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SizedBox()),
        ),
      );
      final terminals = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      terminals.openTab(TerminalProfile.powerShell);
      final paneId = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .focusedPaneId;
      db.server.sessionRows
        ..insert(session(title: 'Resize'))
        ..updatePaneId('s1', paneId);
      await tester.pumpAndSettle();
      return paneId;
    }

    testWidgets('terminal showing: the path is typed at the prompt, quoted, '
        'with no newline, and nothing is queued', (tester) async {
      final paneId = await runSessionInATab(tester);
      final terminals = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final written = <String>[];
      terminals.instanceFor(paneId)!.terminal.onOutput = written.add;

      final outcome = offerFileToSessionWith(
        container.read,
        sessionId: 's1',
        file: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\src\demo\screen shot.png',
        ),
      );

      expect(outcome, SessionOfferOutcome.typedIntoTerminal);
      expect(written, [r'"C:\src\demo\screen shot.png"']);
      expect(container.read(composerAttachmentsProvider), isEmpty);
    });

    testWidgets('chat showing: the file is queued for the composer and '
        'nothing is typed', (tester) async {
      final paneId = await runSessionInATab(tester);
      final terminals = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      terminals.showFaceIn(terminals.groupOfPane(paneId)!, terminal: false);
      final written = <String>[];
      terminals.instanceFor(paneId)!.terminal.onOutput = written.add;

      final outcome = offerFileToSessionWith(
        container.read,
        sessionId: 's1',
        file: shot,
      );

      expect(outcome, SessionOfferOutcome.queuedForComposer);
      expect(container.read(composerAttachmentsProvider)['s1'], [shot]);
      expect(written, isEmpty);
    });
  });
}
