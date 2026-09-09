import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/logging/app_logger.dart';
import 'package:karmashala/src/core/logging/diagnostics.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_permission_support.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/handoff_packet_files.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_wait.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/sessions/domain/handoff_packet.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala/src/features/sessions/data/decision_record_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/decision_record.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';
import 'package:karmashala/src/features/sessions/domain/session_fork.dart';
import 'package:karmashala/src/features/sessions/domain/session_lineage.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/permission_risk.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../terminal/fake_instance.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';

/// Forker's own vocabulary. Deliberately **has no accept-edits**: the carry
/// rule's downwards-only clause is only visible against an agent that cannot
/// express what it is handed, so the shared `testPermissionSupport` (which has
/// all three rungs) would hide exactly what these tests are for.
const _forkerModes = AgentPermissionSupport.axes(
  evidence: 'test fixture — not a real CLI',
  axes: [
    AgentPermissionAxis(
      id: 'mode',
      label: 'Permission mode',
      description: 'How much Forker may do without asking.',
      defaultValueId: 'ask',
      values: [
        AgentPermissionValue(
          id: 'ask',
          label: 'Ask every time',
          shortLabel: 'Ask',
          description: 'Prompts before edits and commands.',
          arguments: ['--careful'],
          permits: PermissionRisk.ask,
          evidence: 'test fixture',
        ),
        AgentPermissionValue(
          id: 'bypass',
          label: 'Bypass',
          shortLabel: 'Bypass',
          description: 'Skips every prompt.',
          arguments: ['--trust-me'],
          permits: PermissionRisk.bypass,
          isDangerous: true,
          evidence: 'test fixture',
        ),
      ],
    ),
  ],
);

/// Mute's only expressible mode is a bypass — the shape that makes the carry
/// rule refuse rather than escalate a careful session onto it.
const _muteModes = AgentPermissionSupport.axes(
  evidence: 'test fixture — not a real CLI',
  axes: [
    AgentPermissionAxis(
      id: 'mode',
      label: 'Permission mode',
      description: 'The only thing Mute can be told.',
      defaultValueId: 'bypass',
      values: [
        AgentPermissionValue(
          id: 'bypass',
          label: 'Bypass',
          shortLabel: 'Bypass',
          description: 'Skips every prompt.',
          arguments: ['--yolo'],
          permits: PermissionRisk.bypass,
          isDangerous: true,
          evidence: 'test fixture',
        ),
      ],
    ),
  ],
);

/// Two agents that differ in exactly the ways the handoff cares about: one
/// forks natively and takes a prompt, the other cannot be told anything.
const _forker = AgentDescriptor(
  id: 'forker',
  displayName: 'Forker CLI',
  binaries: AgentBinaries(windows: ['forker'], posix: ['forker']),
  launch: AgentLaunchSpec(
    permission: _forkerModes,
    interactiveResume: AgentResume.flag('--resume'),
    sessionIdAssignment: AgentSessionIdAssignment.flag('--session-id'),
    prompt: AgentPromptSupport.positional(),
    // Checked, and it has none — the sentence the diagnostics must print
    // instead of typing a packet in silence.
    systemPromptFile: AgentSystemPromptFileSupport.absent(
      evidence: 'test fixture — not a real CLI',
    ),
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

/// Takes a file of extra system prompt — the shape Claude Code has, and the
/// one that decides whether a packet is handed over or typed.
const _briefed = AgentDescriptor(
  id: 'briefed',
  displayName: 'Briefed CLI',
  binaries: AgentBinaries(windows: ['briefed'], posix: ['briefed']),
  launch: AgentLaunchSpec(
    permission: _forkerModes,
    sessionIdAssignment: AgentSessionIdAssignment.flag('--session-id'),
    prompt: AgentPromptSupport.positional(),
    systemPromptFile: AgentSystemPromptFileSupport.append(
      '--append-system-prompt-file',
      evidence: 'test fixture — not a real CLI',
    ),
  ),
  store: AgentStoreSpec(
    homeDirectoryName: '.briefed',
    format: AgentStoreFormat.claudeJsonl,
  ),
);

const _mute = AgentDescriptor(
  id: 'mute',
  displayName: 'Mute CLI',
  binaries: AgentBinaries(windows: ['mute'], posix: ['mute']),
  // Takes no prompt argument and declares no fork: the shape Antigravity has.
  launch: AgentLaunchSpec(
    permission: _muteModes,
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

/// A source session that answers, by appending to the transcript the locator
/// points at — which is how the real thing becomes visible to the service too.
class _AnsweringActions extends SessionActions {
  _AnsweringActions(super.ref, {this.transcript, this.answer});

  final String? transcript;
  final String? answer;
  final sent = <String>[];

  @override
  Future<void> continueSession(String sessionId, String text) async {
    sent.add(text);
    final path = transcript;
    final reply = answer;
    if (path == null || reply == null) return;
    File(path).writeAsStringSync(
      '\n${jsonEncode({
        'type': 'assistant',
        'message': {
          'content': [
            {'type': 'text', 'text': reply},
          ],
        },
      })}',
      mode: FileMode.append,
    );
  }
}

/// A wait that settles at once with a stated verdict. The real one is
/// event-driven and would sit on its bound in a container with no live pane;
/// what these tests are about is what the service does with the answer.
class _SettledWait extends SessionWaitService {
  _SettledWait(super.ref, {this.state = SessionWaitState.done, this.block});

  final SessionWaitState state;
  final SessionBlock? block;

  @override
  SessionBlock? blockedOn(String sessionId) => block;

  @override
  Future<SessionWaitOutcome> wait(
    String sessionId, {
    Duration? bound,
    bool? inputSent,
  }) async => SessionWaitOutcome(
    state: state,
    agentStatus: AgentActivityStatus.idle,
    source: AgentStatusSource.none,
    changed: state == SessionWaitState.done,
    inputSent: inputSent,
  );
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
  Settings settings = const Settings(),
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
  Directory? packetDirectory,
  String? sourceAnswer,
  SessionWaitState waitState = SessionWaitState.done,
  SessionBlock? blockedOn,
}) {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  ProjectDao(db).insert(project());
  RepositoryDao(db).insert(repository());
  AgentInstallationDao(db)
    ..insert(agentInstallation(id: 'a1', agentId: 'forker'))
    ..insert(agentInstallation(id: 'a2', agentId: 'mute'));
  // Only when a test asks: the target list is asserted by name elsewhere.
  if (packetDirectory != null) {
    AgentInstallationDao(db).insert(
      agentInstallation(id: 'a3', agentId: 'briefed'),
    );
  }

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
        const AgentRegistry([_forker, _mute, _briefed]),
      ),
      if (packetDirectory != null)
        handoffPacketFilesProvider.overrideWith(
          (ref) async => HandoffPacketFiles(packetDirectory),
        ),
      sessionActionsProvider.overrideWith(
        (ref) => _AnsweringActions(
          ref,
          transcript: transcriptPath,
          answer: sourceAnswer,
        ),
      ),
      sessionWaitProvider.overrideWith(
        (ref) => _SettledWait(ref, state: waitState, block: blockedOn),
      ),
      settingsControllerProvider.overrideWith(() => _StaticSettings(settings)),
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

/// [mode] null is a session that never chose one and follows the Settings
/// default — the state a continuation has to be able to hand down.
void seedSession(
  AppDatabase db, {
  String id = 'src',
  String installationId = 'a1',
  String? externalSessionId = 'cli-1',
  EnvironmentPath? workingDirectory,
  String? mode = askStored,
}) {
  SessionDao(db).insert(
    session(
      id: id,
      agentInstallationId: installationId,
      workingDirectory: workingDirectory,
    ).copyWith(externalSessionId: externalSessionId, permissionMode: mode),
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
      expect(mute.permission.requested, PermissionRisk.ask);
      expect(mute.permission.selection, PermissionSelection.empty);
      expect(mute.permission.enforced, isFalse);
    });

    test('a session that never chose is measured against each target', () {
      final h = harness(
        settings: const Settings()
            .withPermissions(
              'forker',
              const AgentPermissions(
                newSessions: askStored,
                existingSessions: bypassStored,
              ),
            )
            .withPermissions(
              'mute',
              const AgentPermissions(newSessions: bypassStored),
            ),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db, mode: null);

      final targets = h.container
          .read(sessionHandoffServiceProvider)
          .targetsFor('src');

      // The source chose nothing, so what each row is measured against is the
      // mode that target will actually start under if the new session is left
      // following the default — the **target's** new-session default, not the
      // source agent's existing-session one, which the launch would never use.
      expect(targets.first.permission.requested, PermissionRisk.ask);
      expect(targets.last.permission.selection, bypassSelection);
      expect(targets.last.permission.enforced, isTrue);
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

      // A rejected approach is not filed with the rest: it moves to
      // `## Don't do`, which is the section a reader needs *before* they start
      // work rather than among everything else that was settled.
      expect(packet.decisions, hasLength(1));
      expect(packet.deadEnds, hasLength(1));
      expect(
        text,
        contains('- **The isolate pool deadlocked on Windows.**'),
      );
      expect(text, contains('said by: Forker CLI'));
      // Its evidence is the act that recorded it — never an omitted qualifier.
      expect(
        text,
        contains('evidence: recorded from a `decision_record` call'),
      );
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

      // Every decision survives — counted across both sections it can land
      // in, because the budget is charged once over the whole record.
      expect(
        after.decisions!.length + after.deadEnds!.length,
        15,
      );
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
            permissionMode: bypassSelection,
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
        bypassStored,
      );
    });

    test('a handoff of a session that never chose keeps following the default', () async {
      final path = writeTranscript([('user', 'hello')]);
      final h = harness(
        transcriptPath: path,
        settings: const Settings().withPermissions(
          'forker',
          const AgentPermissions(newSessions: bypassStored),
        ),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db, mode: null);

      final result = await h.container
          .read(sessionHandoffServiceProvider)
          .handoffTo(
            sessionId: 'src',
            targetInstallationId: 'a1',
            instruction: 'Take it from here.',
          );

      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(result.paneId!)!
          .agentLaunch!;
      expect(launch.arguments, contains('--trust-me'));
      expect(
        SessionDao(h.db).getById(result.session.id)!.permissionMode,
        isNull,
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
            permissionMode: acceptEditsSelection,
          );

      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(result.paneId!)!
          .agentLaunch!;
      expect(launch.arguments, contains('--careful'));
      expect(launch.arguments, isNot(contains('--trust-me')));
      expect(
        SessionDao(h.db).getById(result.session.id)!.permissionMode,
        askStored,
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
          .forkSession(sessionId: 'src', permissionMode: bypassSelection);

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
        askStored,
      );
    });

    test('a fork of a session that never chose keeps following the default', () async {
      final h = harness(
        settings: const Settings().withPermissions(
          'forker',
          const AgentPermissions(newSessions: bypassStored),
        ),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db, mode: null);

      final result = await h.container
          .read(sessionHandoffServiceProvider)
          .forkSession(sessionId: 'src');

      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(result.paneId!)!
          .agentLaunch!;
      expect(launch.arguments, contains('--trust-me'));
      // A branch inherits its parent's *state*, not a snapshot of it: the
      // parent follows the setting, so the branch does too. Stamping what the
      // default said today would freeze the branch the moment it was made.
      expect(
        SessionDao(h.db).getById(result.session.id)!.permissionMode,
        isNull,
      );
    });

    test('a fork stamps a mode that had to be reduced to fit the agent', () async {
      final h = harness();
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      // A row naming a mode this build of Forker does not have — what a newer
      // build, or a row written before a mode was withdrawn, leaves behind.
      //
      // Before per-agent modes this reduction came from the *carry rule*, with
      // a shared `acceptEdits` the agent's flag table had no entry for. It
      // cannot come from there any more: a same-agent fork measures the source
      // against a selection already normalised into that agent's vocabulary, so
      // the carry is always exact. An unrecognised stored value is what is left
      // — and the property under test is unchanged.
      seedSession(h.db, mode: acceptEditsStored);

      final result = await h.container
          .read(sessionHandoffServiceProvider)
          .forkSession(sessionId: 'src');

      // Forker has no accept-edits, so the resolution falls to the safest mode
      // it does express. That reduction is a decision this branch must keep —
      // recorded as the mode it actually ran under rather than as a name
      // nothing here understands.
      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(result.paneId!)!
          .agentLaunch!;
      expect(launch.arguments, contains('--careful'));
      expect(launch.arguments, isNot(contains('--trust-me')));
      expect(
        SessionDao(h.db).getById(result.session.id)!.permissionMode,
        askStored,
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

  test('a handoff says what it handed over, and how big it was', () async {
    // A handoff is the one action here that turns one session into two, so
    // when it goes wrong there are two rows and, until now, no record of the
    // decision that joined them. The packet's length is on the line because it
    // is typed into the pane and Claude Code collapses any paste over 800
    // characters into `[Pasted text #N]` — the difference between the next
    // agent reading the brief and reading a placeholder.
    final path = writeTranscript([('user', 'hello')]);
    final h = harness(transcriptPath: path);
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    seedSession(h.db);

    final previous = Diagnostics.instance;
    final records = <LogRecord>[];
    Diagnostics.instance = Diagnostics(echoToConsole: false);
    AppLogger.initialize(onRecord: records.add);
    addTearDown(() {
      Diagnostics.instance = previous;
      AppLogger.initialize();
    });

    await h.container
        .read(sessionHandoffServiceProvider)
        .handoffTo(
          sessionId: 'src',
          targetInstallationId: 'a1',
          instruction: 'Take it from here.',
        );

    final line = records
        .where((r) => r.loggerName == 'sessions.handoff')
        .map((r) => r.message)
        .join('\n');
    expect(line, contains('Handoff from src'));
    expect(line, contains('packet='));
    expect(line, contains('worktree='));
    expect(line, contains('mode='));
    // A real packet, not an empty one — the number has to mean something.
    final size = RegExp(r'packet=(\d+) chars').firstMatch(line);
    expect(size, isNotNull);
    expect(int.parse(size!.group(1)!), greaterThan(0));
  });

  group('how the packet is delivered', () {
    Directory tempDirectory() {
      final dir = Directory.systemTemp.createTempSync('handoff-packets');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      return dir;
    }

    test('is handed over as a file when the target takes one', () async {
      final dir = tempDirectory();
      final h = harness(
        transcriptPath: writeTranscript([('user', 'hello')]),
        packetDirectory: dir,
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final result = await h.container
          .read(sessionHandoffServiceProvider)
          .handoffTo(
            sessionId: 'src',
            targetInstallationId: 'a3',
            instruction: 'Take it from here.',
          );

      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(result.paneId!)!
          .agentLaunch!;
      final flag = launch.arguments.indexOf('--append-system-prompt-file');
      expect(flag, isNot(-1), reason: 'the flag has to reach the CLI');
      final packetPath = launch.arguments[flag + 1];
      // Named by the receiving session, which is the only id that can be swept
      // against a live row later.
      expect(
        packetPath,
        endsWith(HandoffPacketFiles.fileNameFor(result.session.id)),
      );
      expect(
        File(packetPath).readAsStringSync(),
        contains('Handed off from Forker CLI'),
      );
      // And the id we correlate on is *assigned*, not recovered afterwards:
      // it is the same id the file is named by.
      expect(
        launch.arguments,
        containsAllInOrder(['--session-id', result.session.id]),
      );

      // And the opening prompt is the instruction alone. This is the whole
      // point: a packet typed into the pane is what Claude Code collapses into
      // `[Pasted text #N]`.
      expect(launch.arguments.last, endsWith('Take it from here.'));
      expect(launch.arguments.last, isNot(contains('Handed off from')));
    });

    test('stays in the opening prompt for a target that takes none', () async {
      final dir = tempDirectory();
      final h = harness(
        transcriptPath: writeTranscript([('user', 'hello')]),
        packetDirectory: dir,
      );
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

      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(result.paneId!)!
          .agentLaunch!;
      expect(launch.arguments, isNot(contains('--append-system-prompt-file')));
      expect(launch.arguments.last, contains('Handed off from Forker CLI'));
      expect(dir.listSync(), isEmpty);
    });

    test('says in the diagnostics which channel each CLI got', () async {
      final dir = tempDirectory();
      final h = harness(
        transcriptPath: writeTranscript([('user', 'hello')]),
        packetDirectory: dir,
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final previous = Diagnostics.instance;
      final records = <LogRecord>[];
      Diagnostics.instance = Diagnostics(echoToConsole: false);
      AppLogger.initialize(onRecord: records.add);
      addTearDown(() {
        Diagnostics.instance = previous;
        AppLogger.initialize();
      });

      final service = h.container.read(sessionHandoffServiceProvider);
      await service.handoffTo(
        sessionId: 'src',
        targetInstallationId: 'a1',
        instruction: 'Take it from here.',
      );
      await service.handoffTo(
        sessionId: 'src',
        targetInstallationId: 'a3',
        instruction: 'Take it from here.',
      );

      final lines = records.map((r) => r.message).join('\n');
      // The agent that cannot be handed a file says so, with the reason —
      // never silently typed.
      expect(lines, contains('typed — Forker CLI has no system-prompt file'));
      expect(lines, contains('delivery=--append-system-prompt-file'));
      expect(lines, contains('handed over as --append-system-prompt-file'));
    });

    test('retires the packet of a session that is no longer running', () async {
      final dir = tempDirectory();
      final files = HandoffPacketFiles(dir);
      files.write(sessionId: 'gone', packet: 'old', liveSessionIds: const {});
      expect(dir.listSync(), hasLength(1));

      final kept = files.write(
        sessionId: 'fresh',
        packet: 'new',
        liveSessionIds: const {'still-running'},
      );
      expect(kept, isNotNull);
      // `gone` is neither the session being written nor a running one.
      expect(
        dir.listSync().map((e) => p.basename(e.path)),
        [HandoffPacketFiles.fileNameFor('fresh')],
      );
      expect(files.retire('fresh'), isTrue);
      expect(files.retire('fresh'), isFalse);
    });
  });


  group("the source agent's own brief", () {
    test('asks with the compaction prompt and quotes what came back', () async {
      final path = writeTranscript([('user', 'Parse the header.')]);
      final h = harness(
        transcriptPath: path,
        sourceAnswer: 'Progress: the header parses. Next: the body.',
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final brief = await h.container
          .read(sessionHandoffServiceProvider)
          .requestSourceBrief(sessionId: 'src');

      expect(brief.wasWritten, isTrue);
      expect(brief.text, 'Progress: the header parses. Next: the body.');
      final actions =
          h.container.read(sessionActionsProvider) as _AnsweringActions;
      expect(actions.sent.single, kSourceBriefRequest);

      // And it reaches the packet as that agent's own words.
      final packet = await h.container
          .read(sessionHandoffServiceProvider)
          .buildPacket(
            sessionId: 'src',
            targetAgentName: 'Mute CLI',
            instruction: 'Finish it.',
            sourceBrief: brief,
          );
      expect(packet.render(), contains("## In Forker CLI's own words"));
      expect(packet.render(), contains('> Progress: the header parses.'));
    });

    test('a source that answers nothing does not block the handoff', () async {
      final path = writeTranscript([('user', 'Parse the header.')]);
      // No `sourceAnswer`: the request is delivered and the transcript never
      // moves, which is exactly a session that ignored it.
      final h = harness(
        transcriptPath: path,
        waitState: SessionWaitState.timeout,
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final brief = await h.container
          .read(sessionHandoffServiceProvider)
          .requestSourceBrief(sessionId: 'src');

      expect(brief.wasWritten, isFalse);
      expect(brief.notWritten, contains('had not answered'));
      // The bound is the whole of the limit, and the request is still in.
      expect(brief.notWritten, contains('may still be answered'));

      // The handoff goes ahead, packet and all.
      final result = await h.container
          .read(sessionHandoffServiceProvider)
          .handoffTo(
            sessionId: 'src',
            targetInstallationId: 'a1',
            instruction: 'Take it from here.',
            sourceBrief: brief,
          );
      final launch = h.container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(result.paneId!)!
          .agentLaunch!;
      expect(launch.arguments.last, contains('was asked to write this'));
      expect(launch.arguments.last, contains('Handed off from Forker CLI'));
    });

    test('a source stopped for a person is not sent to at all', () async {
      final path = writeTranscript([('user', 'Parse the header.')]);
      final h = harness(
        transcriptPath: path,
        sourceAnswer: 'never reached',
        blockedOn: const SessionBlock(
          kind: 'approvalPrompt',
          text: 'Allow the write?',
        ),
      );
      addTearDown(h.db.close);
      addTearDown(h.container.dispose);
      seedSession(h.db);

      final brief = await h.container
          .read(sessionHandoffServiceProvider)
          .requestSourceBrief(sessionId: 'src');

      expect(brief.wasWritten, isFalse);
      expect(brief.notWritten, contains('stopped waiting for a person'));
      final actions =
          h.container.read(sessionActionsProvider) as _AnsweringActions;
      expect(actions.sent, isEmpty);
    });
  });

}
