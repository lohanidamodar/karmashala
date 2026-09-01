import 'dart:convert';
import 'dart:io';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/core/util/id_generator_provider.dart';
import 'package:chitragupta/src/features/agents/application/agent_providers.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/delivery_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_chat_source.dart';
import 'package:chitragupta/src/features/sessions/application/session_handoff_service.dart';
import 'package:chitragupta/src/features/sessions/application/session_working_directory.dart';
import 'package:chitragupta/src/features/sessions/data/decision_record_dao.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/decision_record.dart';
import 'package:chitragupta/src/features/sessions/domain/session_delivery.dart';
import 'package:chitragupta/src/features/sessions/domain/session_fork.dart';
import 'package:chitragupta/src/features/sessions/domain/session_lineage.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:chitragupta/src/features/settings/domain/settings.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../terminal/fake_instance.dart';
import '../../support/fixtures.dart';

/// Two agents that differ in exactly the ways the handoff cares about: one
/// forks natively and takes a prompt, the other cannot be told anything.
const _forker = AgentDescriptor(
  id: 'forker',
  displayName: 'Forker CLI',
  binaries: AgentBinaries(windows: ['forker'], posix: ['forker']),
  launch: AgentLaunchSpec(
    permissionModes: {
      PermissionMode.ask: PermissionModeMapping.exact(['--careful']),
      PermissionMode.bypass: PermissionModeMapping.exact(['--trust-me']),
    },
    interactiveResume: AgentResume.flag('--resume'),
    sessionIdAssignment: AgentSessionIdAssignment.flag('--session-id'),
    acceptsPromptArgument: true,
    fork: AgentForkSupport.native(
      resume: AgentResume.flag('--resume'),
      extraArguments: ['--fork-session'],
      evidence: 'forker --help',
    ),
  ),
  store: AgentStoreSpec(
    homeDirectoryName: '.forker',
    format: AgentStoreFormat.claudeJsonl,
  ),
);

const _mute = AgentDescriptor(
  id: 'mute',
  displayName: 'Mute CLI',
  binaries: AgentBinaries(windows: ['mute'], posix: ['mute']),
  // Takes no prompt argument and declares no fork: the shape Antigravity has.
  launch: AgentLaunchSpec(
    permissionModes: {
      PermissionMode.bypass: PermissionModeMapping.exact(['--yolo']),
    },
  ),
);

class _FakeLocator implements SessionTranscriptLocator {
  _FakeLocator(this.path);
  final String? path;

  @override
  Future<String?> locate({
    required String agentId,
    required String externalSessionId,
  }) async => path;

  @override
  Future<Map<String, String>> index() async =>
      path == null ? const {} : {'$agentId/$externalId': path!};
}

const agentId = 'claudeCode';
const externalId = 'cli-1';

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;
  @override
  Settings build() => _settings;
}

typedef Harness = ({ProviderContainer container, AppDatabase db});

Harness harness({
  String? transcriptPath,
  SessionDelivery? repoState = const SessionDelivery(
    branch: 'feature/x',
    hasRemote: true,
    baseBranch: 'origin/main',
    defaultBranch: 'main',
    aheadOfBase: 3,
  ),
  String gitStatus = ' M lib/a.dart\nA  lib/b.dart\n?? notes.txt\n',
  Set<String> missingDirectories = const {},
}) {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db)
    ..insert(agentInstallation(id: 'a1', agentId: 'forker'))
    ..insert(agentInstallation(id: 'a2', agentId: 'mute'));

  final git = FakeCommandRunner(
    responder: (request) => CommandResult(
      exitCode: 0,
      stdout: request.arguments.contains('status') ? gitStatus : '',
      stderr: '',
    ),
  );

  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(
        const AgentRegistry([_forker, _mute]),
      ),
      settingsControllerProvider.overrideWith(
        () => _StaticSettings(const Settings()),
      ),
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(fallback: git),
      ),
      hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      sessionTranscriptLocatorProvider.overrideWithValue(
        _FakeLocator(transcriptPath),
      ),
      // Overridden rather than driven through `gh`: the packet's job is to say
      // what it was told, and what git state *reaches* it is the git feature's
      // test, not this one's.
      sessionDeliveryProvider.overrideWith(
        (ref, id) async => repoState ?? SessionDelivery.unknown,
      ),
      // The filesystem seam: nothing under `C:\src\demo` exists on a test
      // machine, so the default would call every recorded directory gone.
      sessionDirectoryPresentProvider.overrideWithValue(
        (directory) => !missingDirectories.contains(directory.path),
      ),
    ],
  );
  return (container: container, db: db);
}

/// A Claude-shaped transcript on disk, so the real reader parses it.
String writeTranscript(List<(String, String)> turns) {
  final dir = Directory.systemTemp.createTempSync('handoff-test');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/session.jsonl');
  file.writeAsStringSync(
    turns
        .map(
          (turn) => jsonEncode({
            'type': turn.$1 == 'user' ? 'user' : 'assistant',
            'message': {
              'content': [
                {'type': 'text', 'text': turn.$2},
              ],
            },
          }),
        )
        .join('\n'),
  );
  return file.path;
}

void seedSession(
  AppDatabase db, {
  String id = 'src',
  String installationId = 'a1',
  String? externalSessionId = 'cli-1',
  EnvironmentPath? workingDirectory,
}) {
  SessionDao(db).insert(
    session(
      id: id,
      agentInstallationId: installationId,
      workingDirectory: workingDirectory,
    ).copyWith(
      externalSessionId: externalSessionId,
      permissionMode: PermissionMode.ask,
    ),
  );
}

void main() {
  group('targets', () {
    test('offers every installed agent, marking the one already running it', () {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final targets = h.container
          .read(sessionHandoffServiceProvider)
          .targetsFor('src');
      expect(targets.map((t) => t.agentName), ['Forker CLI', 'Mute CLI']);
      // The same agent is offered too: "continue this in a fresh session" is a
      // real answer to a full context window.
      expect(targets.first.isSameAgent, isTrue);
      expect(targets.last.isSameAgent, isFalse);
    });

    test('refuses a target that cannot be handed an opening prompt', () {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final mute = h.container
          .read(sessionHandoffServiceProvider)
          .targetsFor('src')
          .firstWhere((t) => t.agentName == 'Mute CLI');
      expect(mute.canReceive, isFalse);
      expect(mute.refusal, contains('takes no opening prompt'));
      // The packet would have been silently dropped, and the new session would
      // have started knowing nothing at all.
      expect(mute.refusal, contains('knowing nothing'));
    });

    test('carries the session mode, refusing to escalate it', () {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final mute = h.container
          .read(sessionHandoffServiceProvider)
          .targetsFor('src')
          .firstWhere((t) => t.agentName == 'Mute CLI');
      // Mute's only expressible mode is bypass, and the session is on `ask`.
      expect(mute.permission.mode, PermissionMode.ask);
      expect(mute.permission.enforced, isFalse);
    });

    test(
      'a session that no longer exists offers nothing rather than throwing',
      () {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        expect(
          h.container.read(sessionHandoffServiceProvider).targetsFor('gone'),
          isEmpty,
        );
      },
    );
  });

  group('the packet', () {
    test('quotes the transcript, names both agents and lists the tree', () async {
      final path = writeTranscript([
        ('user', 'Parse the header.'),
        ('agent', 'Done, in lib/a.dart.'),
      ]);
      final h = harness(transcriptPath: path);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final packet = await h.container
          .read(sessionHandoffServiceProvider)
          .buildPacket(
            sessionId: 'src',
            targetAgentName: 'Mute CLI',
            instruction: 'Finish it.',
            unresolvedTasks: const ['write the tests', '  '],
          );
      final text = packet.render();

      expect(text, contains('# Handed off from Forker CLI'));
      expect(text, contains('**You are:** Mute CLI'));
      // The agent's own turn is attributed to it by name, never to "assistant".
      expect(text, contains('**Forker CLI:**'));
      expect(text, contains('> Done, in lib/a.dart.'));
      expect(text, contains('**The user:**'));
      // Working tree, read through the real git status parser.
      expect(text, contains('lib/a.dart'));
      expect(text, contains('lib/b.dart'));
      expect(text, contains('notes.txt'));
      expect(text, contains('`feature/x` — 3 commits ahead of `origin/main`'));
      // Blank task lines are dropped rather than rendered as empty checkboxes.
      expect(text, contains('- [ ] write the tests'));
      expect('- [ ] '.allMatches(text).length, 1);
      expect(text, endsWith('Finish it.'));
    });

    test('a transcript that cannot be located is stated, not faked', () async {
      final h = harness(transcriptPath: null);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final packet = await h.container
          .read(sessionHandoffServiceProvider)
          .buildPacket(
            sessionId: 'src',
            targetAgentName: 'Mute CLI',
            instruction: 'Finish it.',
          );
      expect(packet.recap, isEmpty);
      expect(packet.render(), contains('Nothing was said in that session yet'));
    });

    test('git refusing to answer is an admission, not a clean tree', () async {
      final h = harness(repoState: null);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final packet = await h.container
          .read(sessionHandoffServiceProvider)
          .buildPacket(
            sessionId: 'src',
            targetAgentName: 'Mute CLI',
            instruction: 'Finish it.',
          );
      expect(packet.render(), contains('unknown (git could not be asked)'));
    });
  });

  group('the decision record in the packet', () {
    void record(
      AppDatabase db, {
      String sessionId = 'src',
      DecisionKind kind = DecisionKind.approachRejected,
      String summary = 'The isolate pool deadlocked on Windows.',
      DecisionOrigin origin = DecisionOrigin.decisionTool,
      String? originId,
      String? decidedBy = 'Forker CLI',
      int minute = 0,
    }) => DecisionRecordDao(db).append(
      DecisionRecord(
        sessionId: sessionId,
        kind: kind,
        summary: summary,
        origin: origin,
        originId: originId,
        decidedBy: decidedBy,
        recordedAt: DateTime.utc(2026, 8, 31, 12, minute),
      ),
    );

    test('carries what the session decided, ahead of what it said', () async {
      final path = writeTranscript([('user', 'Parse the header.')]);
      final h = harness(transcriptPath: path);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);
      record(h.db);
      record(
        h.db,
        kind: DecisionKind.verificationVerdict,
        summary: 'Pass — the header parses.',
        origin: DecisionOrigin.verificationRun,
        originId: 'v-1',
        minute: 5,
      );
      // Another session's decisions are its own.
      record(h.db, sessionId: 'other', summary: 'Nothing to do with this.');

      final packet = await h.container
          .read(sessionHandoffServiceProvider)
          .buildPacket(
            sessionId: 'src',
            targetAgentName: 'Mute CLI',
            instruction: 'Finish it.',
          );
      final text = packet.render();

      expect(packet.decisions, hasLength(2));
      expect(text, contains('> The isolate pool deadlocked on Windows.'));
      expect(text, contains('> Pass — the header parses.'));
      expect(text, contains('from verification run `v-1`'));
      expect(text, contains('decided by Forker CLI'));
      expect(text, isNot(contains('Nothing to do with this.')));
      expect(
        text.indexOf('## Decisions on record'),
        lessThan(text.indexOf('## Conversation so far')),
      );
    });

    test('a session that recorded nothing says "not recorded"', () async {
      final h = harness(transcriptPath: writeTranscript([('user', 'Hi.')]));
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final packet = await h.container
          .read(sessionHandoffServiceProvider)
          .buildPacket(
            sessionId: 'src',
            targetAgentName: 'Mute CLI',
            instruction: 'Finish it.',
          );
      expect(packet.decisions, isEmpty);
      expect(
        packet.render(),
        contains('nothing was written to this session\'s decision record'),
      );
    });

    test('the recap is what gives when both will not fit', () async {
      // A long session: the case the whole feature is for.
      final path = writeTranscript([
        for (var i = 0; i < 80; i++) ('user', 'turn $i ${'.' * 200}'),
      ]);
      final h = harness(transcriptPath: path);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final service = h.container.read(sessionHandoffServiceProvider);
      final before = await service.buildPacket(
        sessionId: 'src',
        targetAgentName: 'Mute CLI',
        instruction: 'Finish it.',
      );

      for (var i = 0; i < 15; i++) {
        record(h.db, summary: 'Decision $i ${'.' * 150}', minute: i);
      }
      final after = await service.buildPacket(
        sessionId: 'src',
        targetAgentName: 'Mute CLI',
        instruction: 'Finish it.',
      );

      // Every decision survives...
      expect(after.decisions, hasLength(15));
      expect(after.omittedDecisions, 0);
      for (var i = 0; i < 15; i++) {
        expect(after.render(), contains('Decision $i'));
      }
      // ...and the quoted tail is what paid for them.
      expect(after.recap.length, lessThan(before.recap.length));
      expect(after.omittedTurns, greaterThan(before.omittedTurns));
    });
  });

  group('handing off', () {
    Future<void> expectLaunched(
      Harness h, {
      required String childId,
      required SessionLink link,
    }) async {
      final child = SessionDao(h.db).getById(childId)!;
      expect(child.parentSessionId, 'src');
      expect(child.parentLink, link);
      // The old session is untouched — not ended, not detached, not marked.
      expect(SessionDao(h.db).getById('src')!.status, session().status);
    }

    test('starts the target through the launcher and links the two', () async {
      final path = writeTranscript([('user', 'hello')]);
      final h = harness(transcriptPath: path);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final result = await h.container
          .read(sessionHandoffServiceProvider)
          .handoffTo(
            sessionId: 'src',
            targetInstallationId: 'a1',
            instruction: 'Take it from here.',
          );
      await expectLaunched(
        h,
        childId: result.session.id,
        link: SessionLink.handoff,
      );

      // The packet arrived as the opening prompt, through the one launch path.
      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(result.paneId!)!
          .agentLaunch!;
      expect(launch.arguments.last, contains('Handed off from Forker CLI'));
      expect(launch.arguments.last, endsWith('Take it from here.'));
      // The session's own mode travelled with it.
      expect(launch.arguments, contains('--careful'));
    });

    test('runs under the mode the user picked for the target', () async {
      final path = writeTranscript([('user', 'hello')]);
      final h = harness(transcriptPath: path);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final result = await h.container
          .read(sessionHandoffServiceProvider)
          .handoffTo(
            sessionId: 'src',
            targetInstallationId: 'a1',
            instruction: 'Take it from here.',
            permissionMode: PermissionMode.bypass,
          );

      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(result.paneId!)!
          .agentLaunch!;
      // The pick, not the source session's `ask`, is what reached the command
      // line — which is the only place a permission mode is ever real.
      expect(launch.arguments, contains('--trust-me'));
      expect(launch.arguments, isNot(contains('--careful')));
      // And it is stamped on the row, so the next resume runs under it too.
      expect(
        SessionDao(h.db).getById(result.session.id)!.permissionMode,
        PermissionMode.bypass,
      );
    });

    test('a picked mode the target cannot express is not escalated', () async {
      final path = writeTranscript([('user', 'hello')]);
      final h = harness(transcriptPath: path);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      // Forker has no accept-edits, and its only other mode is more permissive
      // than the pick. The carry rule answers with the safest mode it does
      // have rather than the nearest one.
      final result = await h.container
          .read(sessionHandoffServiceProvider)
          .handoffTo(
            sessionId: 'src',
            targetInstallationId: 'a1',
            instruction: 'Take it from here.',
            permissionMode: PermissionMode.acceptEdits,
          );

      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(result.paneId!)!
          .agentLaunch!;
      expect(launch.arguments, contains('--careful'));
      expect(launch.arguments, isNot(contains('--trust-me')));
      expect(
        SessionDao(h.db).getById(result.session.id)!.permissionMode,
        PermissionMode.ask,
      );
    });

    test('refuses a target that cannot receive the packet', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      await expectLater(
        h.container
            .read(sessionHandoffServiceProvider)
            .handoffTo(
              sessionId: 'src',
              targetInstallationId: 'a2',
              instruction: 'Take over.',
            ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('takes no opening prompt'),
          ),
        ),
      );
      // Nothing was created for a launch that must not happen.
      expect(SessionDao(h.db).getAll(), hasLength(1));
    });

    test(
      'refuses an empty instruction, saying why it is the user\'s part',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        seedSession(h.db);

        await expectLater(
          h.container
              .read(sessionHandoffServiceProvider)
              .handoffTo(
                sessionId: 'src',
                targetInstallationId: 'a1',
                instruction: '   ',
              ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('only you can write'),
            ),
          ),
        );
      },
    );
  });

  group('forking', () {
    test(
      'a native fork runs the CLI\'s own fork arguments, not a packet',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        seedSession(h.db);

        final service = h.container.read(sessionHandoffServiceProvider);
        expect(service.forkPlanFor('src').kind, SessionForkKind.native);

        final result = await service.forkSession(sessionId: 'src');
        final child = SessionDao(h.db).getById(result.session.id)!;
        expect(child.parentLink, SessionLink.fork);
        expect(child.title, 'Work (fork)');

        final launch = h.container
            .read(terminalSessionsControllerProvider.notifier)
            .instanceFor(result.paneId!)!
            .agentLaunch!;
        expect(
          launch.arguments,
          containsAllInOrder(['--resume', 'cli-1', '--fork-session']),
        );
        // No id of ours is offered: the CLI is being asked to mint a new one,
        // and naming the old one alongside would contradict that.
        expect(launch.arguments, isNot(contains('--session-id')));
      },
    );

    test('a fork runs under the mode the user picked for it', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final result = await h.container
          .read(sessionHandoffServiceProvider)
          .forkSession(sessionId: 'src', permissionMode: PermissionMode.bypass);

      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(result.paneId!)!
          .agentLaunch!;
      expect(launch.arguments, contains('--trust-me'));
      expect(launch.arguments, isNot(contains('--careful')));
      // The branch runs under the picked mode; the session it came from is
      // left on its own.
      expect(
        SessionDao(h.db).getById('src')!.permissionMode,
        PermissionMode.ask,
      );
    });

    test('a second fork of the same conversation is numbered', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);
      final service = h.container.read(sessionHandoffServiceProvider);
      await service.forkSession(sessionId: 'src');
      final second = await service.forkSession(sessionId: 'src');
      expect(
        SessionDao(h.db).getById(second.session.id)!.title,
        'Work (fork 2)',
      );
    });

    test(
      'a conversation with no CLI id degrades to a handoff, and says so',
      () async {
        final path = writeTranscript([('user', 'hello')]);
        final h = harness(transcriptPath: path);
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        seedSession(h.db, externalSessionId: null);

        final service = h.container.read(sessionHandoffServiceProvider);
        final plan = service.forkPlanFor('src');
        expect(plan.kind, SessionForkKind.handoff);
        expect(plan.explanation, contains('never learned its id for this one'));

        final result = await service.forkSession(sessionId: 'src');
        final child = SessionDao(h.db).getById(result.session.id)!;
        // Still a fork in the lineage — that is what the user asked for and got.
        expect(child.parentLink, SessionLink.fork);

        final launch = h.container
            .read(terminalSessionsControllerProvider.notifier)
            .instanceFor(result.paneId!)!
            .agentLaunch!;
        expect(launch.arguments, isNot(contains('--fork-session')));
        // And the packet frames it as a branch, not a takeover.
        expect(launch.arguments.last, contains('Forked from Forker CLI'));
        expect(
          launch.arguments.last,
          contains('original session still exists'),
        );
      },
    );

    test(
      'an agent that declares no fork is refused before anything runs',
      () async {
        final h = harness();
        addTearDown(h.db.close);
        addTearDown(h.container.dispose);
        seedSession(h.db, installationId: 'a2');

        await expectLater(
          h.container
              .read(sessionHandoffServiceProvider)
              .forkSession(sessionId: 'src'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('no verified way to fork'),
            ),
          ),
        );
        expect(SessionDao(h.db).getAll(), hasLength(1));
      },
    );
  });

  group('lineage', () {
    test('a handoff and a fork show up on the parent, told apart', () async {
      final path = writeTranscript([('user', 'hello')]);
      final h = harness(transcriptPath: path);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);
      final service = h.container.read(sessionHandoffServiceProvider);

      final handed = await service.handoffTo(
        sessionId: 'src',
        targetInstallationId: 'a1',
        instruction: 'Take over.',
      );
      final forked = await service.forkSession(sessionId: 'src');

      final dao = SessionDao(h.db);
      expect(dao.parentOf('src'), isNull, reason: 'the source is a root');
      // Both children hang off the same parent and are distinguishable, which
      // is the whole reason the link kind is stored rather than inferred: the
      // two rows are otherwise identical in shape.
      final children = dao.childrenOf('src');
      expect(
        children.map((c) => c.parentLink).toList(),
        containsAll([SessionLink.handoff, SessionLink.fork]),
      );
      expect(
        children.map((c) => c.id).toList(),
        containsAll([handed.session.id, forked.session.id]),
      );
    });

    test('the child knows what it came from, and by which route', () async {
      final path = writeTranscript([('user', 'hello')]);
      final h = harness(transcriptPath: path);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final handed = await h.container
          .read(sessionHandoffServiceProvider)
          .handoffTo(
            sessionId: 'src',
            targetInstallationId: 'a1',
            instruction: 'Take over.',
          );

      final child = SessionDao(h.db).getById(handed.session.id)!;
      expect(child.parentSessionId, 'src');
      expect(child.parentLink, SessionLink.handoff);
      expect(
        AgentInstallationDao(h.db).getById(child.agentInstallationId)!.agentId,
        'forker',
      );
      // Phrased child-first so a sidebar can render it as a sentence without
      // the explorer having to know the enum.
      expect(child.parentLink!.phrase, 'handed off from');
    });
  });

  group('where a continuation runs', () {
    const subdirectory = r'C:\src\demo\app\packages\ui';
    const elsewhere = EnvironmentPath(
      environmentId: 'windows',
      path: subdirectory,
    );

    test('a native fork continues in the source session\'s directory', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db, workingDirectory: elsewhere);

      final forked = await h.container
          .read(sessionHandoffServiceProvider)
          .forkSession(sessionId: 'src');

      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(forked.paneId!)!
          .agentLaunch!;
      expect(launch.workingDirectory, subdirectory);
      // A fork of a session that has no worktree still has none: the directory
      // is where the work is, not a claim about how it is checked out.
      final child = SessionDao(h.db).getById(forked.session.id)!;
      expect(child.worktree, isNull);
      expect(child.useWorktree, isFalse);
      expect(child.workingDirectory, elsewhere);
    });

    test('a handoff continues in the source session\'s directory', () async {
      final path = writeTranscript([('user', 'hello')]);
      final h = harness(transcriptPath: path);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db, workingDirectory: elsewhere);

      final handed = await h.container
          .read(sessionHandoffServiceProvider)
          .handoffTo(
            sessionId: 'src',
            targetInstallationId: 'a1',
            instruction: 'Take over.',
          );

      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(handed.paneId!)!
          .agentLaunch!;
      expect(launch.workingDirectory, subdirectory);
    });

    test('a fork into a new worktree goes to the worktree, not here', () async {
      // `intoNewWorktree` is the user asking for a clean checkout. Carrying the
      // source directory across would put the branch back where it came from.
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db, workingDirectory: elsewhere);

      final forked = await h.container
          .read(sessionHandoffServiceProvider)
          .forkSession(sessionId: 'src', intoNewWorktree: true);

      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(forked.paneId!)!
          .agentLaunch!;
      expect(launch.workingDirectory, isNot(subdirectory));
      expect(SessionDao(h.db).getById(forked.session.id)!.useWorktree, isTrue);
    });

    test('the packet names the directory the work is actually in', () async {
      final path = writeTranscript([('user', 'hello')]);
      final h = harness(transcriptPath: path);
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db, workingDirectory: elsewhere);

      final packet = await h.container
          .read(sessionHandoffServiceProvider)
          .buildPacket(
            sessionId: 'src',
            targetAgentName: 'Forker CLI',
            instruction: 'Take over.',
          );

      expect(packet.workingDirectory, subdirectory);
    });
  });
}
