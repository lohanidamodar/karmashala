import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_transcript_reader.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_activity_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_event_types.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/sessions/domain/tool_activity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// **What one session is doing right now**, derived from the transcript the
/// conversation is already reading.
///
/// Everything here is about the trap named in the design: an unanswered
/// `tool_use` means "running now" and "the transcript stops here" equally, and a
/// strip that cannot tell them apart will confidently report a call on a session
/// that died hours ago.
void main() {
  /// The instant the fixture transcript is written at.
  final issued = DateTime.utc(2026, 9, 2, 10);

  TranscriptMessage call({
    required String id,
    String name = 'Bash',
    String subject = 'git status',
    DateTime? at,
    bool answered = false,
  }) => TranscriptMessage(
    role: 'tool',
    text: '$name($subject)',
    tool: ToolActivity(
      name: name,
      subject: subject,
      output: answered ? 'clean' : null,
    ),
    at: at ?? issued,
    pendingToolUseId: answered ? null : id,
  );

  ProviderContainer containerFor({
    required List<TranscriptMessage> messages,
    AgentActivityStatus status = AgentActivityStatus.working,
    SessionStatus rowStatus = SessionStatus.running,
  }) {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Session',
        useWorktree: false,
        status: rowStatus,
        createdAt: testTime,
        surface: SessionSurface.pane,
        externalSessionId: 'ext-1',
      ),
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeCode,
              sessionId: id,
              status: status,
              observedAt: testTime,
              source: AgentStatusSource.stateFile,
            ),
          ),
        ),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(messages),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<SessionActivity> activityFor({
    required List<TranscriptMessage> messages,
    AgentActivityStatus status = AgentActivityStatus.working,
    SessionStatus rowStatus = SessionStatus.running,
  }) async {
    final container = containerFor(
      messages: messages,
      status: status,
      rowStatus: rowStatus,
    );
    final subscription = container.listen(
      sessionOutstandingCallsProvider('s1'),
      (_, _) {},
    );
    // Held open by this test rather than only by the provider: when a gate
    // closes, the provider never watches the transcript, and awaiting an
    // `autoDispose` stream nobody is listening to disposes it mid-flight.
    final sources = [
      container.listen(agentSessionStatusProvider('s1'), (_, _) {}),
      container.listen(sessionChatTranscriptProvider('s1'), (_, _) {}),
    ];
    await container.read(agentSessionStatusProvider('s1').future);
    await container.read(sessionChatTranscriptProvider('s1').future);
    // Read after the streams answered, then let go.
    final activity = subscription.read();
    for (final source in sources) {
      source.close();
    }
    return activity;
  }

  test('a tool_use with no tool_result is outstanding', () async {
    final activity = await activityFor(messages: [call(id: 't1')]);

    expect(activity.calls.single.summary, 'Bash(git status)');
    expect(activity.calls.single.startedAt, issued);
    expect(activity.runningAt(issued.add(const Duration(seconds: 4))), [
      activity.calls.single,
    ]);
  });

  test('...and stops being outstanding once its result arrives', () async {
    final activity = await activityFor(
      messages: [call(id: 't1', answered: true)],
    );

    expect(activity.calls, isEmpty);
  });

  // Half of the trap. A crashed agent, a killed pane, a transcript cut short by
  // the remote tail bound and a turn the user abandoned all leave the same
  // unanswered call behind, and none of them is work in progress.
  group('a session that is not working shows nothing', () {
    for (final status in [
      AgentActivityStatus.idle,
      AgentActivityStatus.failed,
      AgentActivityStatus.unknown,
      AgentActivityStatus.awaitingApproval,
    ]) {
      test('status ${status.name}', () async {
        final activity = await activityFor(
          messages: [call(id: 't1')],
          status: status,
        );

        expect(
          activity.calls,
          isEmpty,
          reason: 'an unanswered call on a ${status.name} session is a '
              'transcript that stopped, not a command that is running',
        );
      });
    }
  });

  // `SessionEngine.stop` writes `cancelled` on the row before any status source
  // has a chance to notice, so the row is the faster of the two gates.
  test('a stopped session shows nothing, whatever the status source says',
      () async {
    final activity = await activityFor(
      messages: [call(id: 't1')],
      rowStatus: SessionStatus.cancelled,
    );

    expect(activity.calls, isEmpty);
  });

  // The other half of the trap. Without a bound this reports `Bash · 4h12m` on
  // a session that died before lunch — a confident lie about the user's own
  // machine, which is worse than showing nothing.
  test('an implausibly old call ages out', () async {
    final activity = await activityFor(messages: [call(id: 't1')]);

    final justInside = issued.add(
      kOutstandingCallMaxAge - const Duration(seconds: 1),
    );
    final justOutside = issued.add(
      kOutstandingCallMaxAge + const Duration(seconds: 1),
    );

    expect(activity.runningAt(justInside), hasLength(1));
    expect(activity.runningAt(justOutside), isEmpty);
    expect(
      activity.runningAt(issued.add(const Duration(hours: 4, minutes: 12))),
      isEmpty,
    );
  });

  test('a clock that runs behind the transcript never yields a negative age',
      () async {
    final activity = await activityFor(messages: [call(id: 't1')]);

    expect(
      activity.calls.single.ageAt(issued.subtract(const Duration(minutes: 5))),
      Duration.zero,
    );
  });

  test('a Task call is a subagent, by the name the protocol uses', () async {
    final activity = await activityFor(
      messages: [
        call(id: 't1'),
        call(id: 't2', name: kSubagentToolName, subject: 'review the diff'),
      ],
    );

    expect(activity.calls.map((c) => c.isSubagent), [false, true]);
    expect(activity.calls.last.summary, '$kSubagentToolName(review the diff)');
  });

  test('several unanswered calls all come back, oldest first', () async {
    final activity = await activityFor(
      messages: [
        call(id: 't1', subject: 'flutter test'),
        call(id: 't2', subject: 'git log', at: issued.add(const Duration(seconds: 30))),
        call(id: 't3', name: 'Read', subject: '/repo/main.dart', answered: true),
      ],
    );

    expect(activity.calls.map((c) => c.summary), [
      'Bash(flutter test)',
      'Bash(git log)',
    ]);
  });

  // Without a timestamp there is no age, and without an age there is no way to
  // retire the call — so it is dropped rather than shown with an age we made up.
  test('a call whose line carried no timestamp is not shown', () async {
    final activity = await activityFor(
      messages: [
        TranscriptMessage(
          role: 'tool',
          text: 'Bash(git status)',
          tool: const ToolActivity(name: 'Bash', subject: 'git status'),
          pendingToolUseId: 't1',
        ),
      ],
    );

    expect(activity.calls, isEmpty);
  });

  test('a transcript with no tool rows at all is quiet', () async {
    final activity = await activityFor(
      messages: [
        TranscriptMessage(role: 'user', text: 'hello', at: issued),
        TranscriptMessage(role: 'agent', text: 'hi', at: issued),
      ],
    );

    expect(activity, SessionActivity.none);
  });

  // The strip is repainted on a one-second tick; a poll that changed nothing
  // must hand it a value it recognises rather than a new list of the same calls.
  test('two identical derivations compare equal', () {
    final one = SessionActivity(outstandingCallsIn([call(id: 't1')]));
    final two = SessionActivity(outstandingCallsIn([call(id: 't1')]));

    expect(one, two);
    expect(one.hashCode, two.hashCode);
    expect(
      one,
      isNot(
        SessionActivity(outstandingCallsIn([call(id: 't2', subject: 'git log')])),
      ),
    );
  });
}
