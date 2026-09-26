import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_activity_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala_session/launch.dart';
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
///
/// What tells them apart is **whether the session is still observably working**
/// — a reading the app already takes every 1.2 s — and not how long the call has
/// been out. The two long-call cases below are the measurements that killed the
/// old thirty-minute ceiling.
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
    SessionSurface surface = SessionSurface.pane,
    DateTime? observedAt,
    String? externalSessionId = 'ext-1',
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
        surface: surface,
        externalSessionId: externalSessionId,
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
              observedAt: observedAt ?? issued,
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
    SessionSurface surface = SessionSurface.pane,
    DateTime? observedAt,
    String? externalSessionId = 'ext-1',
  }) async {
    final container = containerFor(
      messages: messages,
      status: status,
      rowStatus: rowStatus,
      surface: surface,
      observedAt: observedAt,
      externalSessionId: externalSessionId,
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
          reason:
              'an unanswered call on a ${status.name} session is a '
              'transcript that stopped, not a command that is running',
        );
      });
    }
  });

  // `SessionEngine.stop` writes `cancelled` on the row before any status source
  // has a chance to notice, so the row is the faster of the two gates.
  test(
    'a stopped session shows nothing, whatever the status source says',
    () async {
      final activity = await activityFor(
        messages: [call(id: 't1')],
        rowStatus: SessionStatus.cancelled,
      );

      expect(activity.calls, isEmpty);
    },
  );

  // A session outside our panes renders from the engine's event log, which
  // emits `tool.call` and never `tool.result` — nothing emits one — so every
  // call in it is unanswered by construction and would read as running forever.

  // **The measurement that replaced the thirty-minute ceiling.** Two subagents
  // launched from this repo on 2026-09-07 reported 4,549,121 ms and 4,798,063 ms
  // of runtime — 76 and 80 minutes — and the longest unanswered tool window in
  // the owner's whole Claude Code store is a `Bash` call at 514.8 minutes. A
  // ceiling above every real call is not a thing that can be chosen; the age of
  // a call says nothing about whether it is running.
  group(
    'a call is running for as long as the session is observably working',
    () {
      for (final (name, elapsed) in [
        ('a 76-minute subagent', const Duration(milliseconds: 4549121)),
        ('an 80-minute subagent', const Duration(milliseconds: 4798063)),
        ('a 514-minute Bash call', const Duration(minutes: 514, seconds: 48)),
      ]) {
        test(name, () async {
          final activity = await activityFor(messages: [call(id: 't1')]);

          expect(activity.calls, hasLength(1));
          expect(activity.calls.single.ageAt(issued.add(elapsed)), elapsed);
        });
      }
    },
  );

  test(
    'a clock that runs behind the transcript never yields a negative age',
    () async {
      final activity = await activityFor(messages: [call(id: 't1')]);

      expect(
        activity.calls.single.ageAt(
          issued.subtract(const Duration(minutes: 5)),
        ),
        Duration.zero,
      );
    },
  );

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
        call(
          id: 't2',
          subject: 'git log',
          at: issued.add(const Duration(seconds: 30)),
        ),
        call(
          id: 't3',
          name: 'Read',
          subject: '/repo/main.dart',
          answered: true,
        ),
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
    expect(
      activity.blindSpot,
      isNull,
      reason: 'we could read the record and there was nothing in it',
    );
  });

  // §19, on the wire and on screen alike: "nothing is running" and "we cannot
  // tell what is running" are different sentences.
  group('a working session with no record to read says so', () {
    // The window right after a launch: the pane is up and the agent is already
    // working, and the CLI has not told us its session id yet — so there is no
    // transcript to find. The chat source answers that with an empty list and
    // never an error, on purpose, which is exactly the shape that used to read
    // as "nothing is running".
    test('one of ours, with no CLI session id yet', () async {
      final activity = await activityFor(
        messages: [call(id: 't1')],
        externalSessionId: null,
      );

      expect(activity.blindSpot, ActivityBlindSpot.noRecord);
      expect(activity.calls, isEmpty);
    });

    test('a session outside our panes', () async {
      final activity = await activityFor(
        messages: [call(id: 't1')],
        surface: SessionSurface.external,
      );

      expect(activity.blindSpot, ActivityBlindSpot.noRecord);
    });
  });

  // The badge one row above already says `unknown`, and §19's own rule is one
  // reading rather than two — so this is not a second hedge, it is silence.
  test('a session nothing can see makes no claim either way', () async {
    final activity = await activityFor(
      messages: [call(id: 't1')],
      status: AgentActivityStatus.unknown,
    );

    expect(activity, SessionActivity.none);
  });

  /// The `Agent` row of a subagent Claude Code is running in the background.
  ///
  /// Answered — `pendingToolUseId` is null, because the CLI replied to the
  /// parent's call within 0.2 minutes — and still running, which is the whole
  /// gap. The reader puts the CLI's own agent id on the row; see
  /// [TranscriptMessage.pendingBackgroundAgentId].
  TranscriptMessage backgroundSubagent({
    String agentId = 'a809fe33a06af42de',
    String subject = 'review the diff',
    DateTime? at,
  }) => TranscriptMessage(
    role: 'tool',
    text: '$kSubagentToolName($subject)',
    tool: ToolActivity(
      name: kSubagentToolName,
      subject: subject,
      output: 'Async agent launched successfully.',
    ),
    at: at ?? issued,
    pendingBackgroundAgentId: agentId,
  );

  group('a background subagent is running though its call was answered', () {
    test('it reaches the strip at all', () async {
      final activity = await activityFor(messages: [backgroundSubagent()]);

      expect(activity.calls.single.summary, 'Agent(review the diff)');
      expect(activity.calls.single.isSubagent, isTrue);
      expect(activity.blindSpot, isNull);
    });

    // **The real case, not a hypothetical.** Two subagents launched from this
    // repo on 2026-09-07 ran 4,549,121 ms and 4,798,063 ms. Neither was ever an
    // outstanding call for more than a moment, so before this the strip said
    // nothing for 76 and 80 minutes while the badge said Working.
    for (final (name, elapsed) in [
      ('a 76-minute background subagent', Duration(milliseconds: 4549121)),
      ('an 80-minute background subagent', Duration(milliseconds: 4798063)),
    ]) {
      test(name, () async {
        final activity = await activityFor(messages: [backgroundSubagent()]);

        expect(activity.calls, hasLength(1));
        expect(activity.calls.single.ageAt(issued.add(elapsed)), elapsed);
      });
    }

    test('the age is the transcript\'s, never a first sighting', () async {
      final launched = issued.subtract(const Duration(minutes: 76));
      final activity = await activityFor(
        messages: [backgroundSubagent(at: launched)],
      );

      expect(activity.calls.single.startedAt, launched);
    });

    test('it is not counted twice against its own answered call', () async {
      // The reader clears `pendingToolUseId` in the same step that records the
      // launch, so the two can never both be set — asserted here because a
      // double count is what would turn one subagent into "2 subagents
      // running".
      final activity = await activityFor(messages: [backgroundSubagent()]);

      expect(activity.calls, hasLength(1));
    });

    test('it joins foreground calls in transcript order', () async {
      final activity = await activityFor(
        messages: [
          backgroundSubagent(subject: 'audit the diff'),
          call(
            id: 't1',
            subject: 'flutter test',
            at: issued.add(const Duration(minutes: 1)),
          ),
        ],
      );

      expect(activity.calls.map((c) => c.summary), [
        'Agent(audit the diff)',
        'Bash(flutter test)',
      ]);
      expect(activity.calls.map((c) => c.isSubagent), [true, false]);
    });

    test('a session that has stopped working claims none of them', () async {
      // The one backstop, and it is the same one the outstanding rule uses. A
      // ledger entry means "launched and unreported", which a session whose
      // CLI went away also produces — so nothing is drawn for a session the
      // app cannot see working.
      for (final status in [
        AgentActivityStatus.idle,
        AgentActivityStatus.unknown,
        AgentActivityStatus.awaitingApproval,
      ]) {
        final activity = await activityFor(
          messages: [backgroundSubagent()],
          status: status,
        );

        expect(activity, SessionActivity.none, reason: status.name);
      }
    });

    test('a finished row claims none of them', () async {
      final activity = await activityFor(
        messages: [backgroundSubagent()],
        rowStatus: SessionStatus.cancelled,
      );

      expect(activity, SessionActivity.none);
    });

    test('a background subagent with no timestamp is not shown', () async {
      // Same discipline as a foreground call: no instant, no age, and an age we
      // invented would be a claim we were inventing.
      final activity = await activityFor(
        messages: [
          TranscriptMessage(
            role: 'tool',
            text: 'Agent(review the diff)',
            tool: const ToolActivity(
              name: kSubagentToolName,
              subject: 'review the diff',
            ),
            pendingBackgroundAgentId: 'a1',
          ),
        ],
      );

      expect(activity.calls, isEmpty);
      expect(activity.blindSpot, isNull);
    });
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
        SessionActivity(
          outstandingCallsIn([call(id: 't2', subject: 'git log')]),
        ),
      ),
    );
  });
}
