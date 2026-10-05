import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The sessions domain at the server (slice 1c): the rows, the checkouts each
/// spans, the records and the imported history — the rules each write
/// follows, what every other client is told, and what the server tells of
/// its own writes.
void main() {
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  late Set<String> running;
  final now = DateTime.utc(2026, 9, 26, 12);

  setUp(() {
    db = AppDatabase.memory();
    running = {};
    service = DataService(db, clock: () => now, runsSession: running.contains);
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
    const at = '2026-01-01T00:00:00.000Z';
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      "VALUES ('windows', 'windowsNative', 'Windows', ?);",
      [at],
    );
    for (final (id, name) in [('p1', 'Demo'), ('p2', 'Other')]) {
      db.execute(
        'INSERT INTO projects '
        '(id, name, root_environment_id, root_path, created_at) '
        "VALUES (?, ?, 'windows', ?, ?);",
        [id, name, 'C:\\src\\$id', at],
      );
    }
    for (final (id, project) in [('r1', 'p1'), ('r2', 'p1'), ('r3', 'p2')]) {
      db.execute(
        'INSERT INTO repositories '
        '(id, project_id, name, environment_id, path, created_at) '
        "VALUES (?, ?, ?, 'windows', ?, ?);",
        [id, project, id, 'C:\\src\\$id', at],
      );
    }
    db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, created_at) '
      "VALUES ('a1', 'claude-code', 'windows', 'claude', ?);",
      [at],
    );
  });
  tearDown(() => db.close());

  Matcher refused(DataRefusalCode code, [String? words]) => throwsA(
    isA<DataRefused>()
        .having((r) => r.code, 'code', code)
        .having((r) => r.message, 'message', contains(words ?? '')),
  );

  Session row({
    String id = 's1',
    String repositoryId = 'r1',
    String title = 'Work',
    SessionStatus status = SessionStatus.created,
    String? externalSessionId,
    String? parentSessionId,
  }) => Session(
    id: id,
    repositoryId: repositoryId,
    agentInstallationId: 'a1',
    title: title,
    useWorktree: false,
    status: status,
    createdAt: now,
    externalSessionId: externalSessionId,
    parentSessionId: parentSessionId,
  );

  SessionsSnapshot snapshot() => app.handle(const SessionsList()).value;

  List<DataChange> lastTold() => told.last.changes;

  group('rows', () {
    test('a created row is stored with its primary checkout and the others, '
        'and told', () {
      final created = app
          .handle(SessionCreate(row(), repositories: const ['r2']))
          .value;
      expect(created.title, 'Work');
      final links = snapshot().links['s1']!;
      expect(
        [for (final l in links) '${l.repositoryId}:${l.role}'],
        ['r1:primary', 'r2:additional'],
      );
      expect(lastTold().whereType<SessionRowChanged>().single.session.id, 's1');
      expect(
        lastTold().whereType<SessionLinksChanged>().single.links,
        hasLength(2),
      );
    });

    test('a taken id, a blank title, and an unknown checkout, installation or '
        'parent are refused', () {
      app.handle(SessionCreate(row()));
      expect(
        () => app.handle(SessionCreate(row())),
        refused(DataRefusalCode.invalid, 'exists'),
      );
      expect(
        () => app.handle(SessionCreate(row(id: 's2', title: '  '))),
        refused(DataRefusalCode.invalid, 'title'),
      );
      expect(
        () => app.handle(SessionCreate(row(id: 's3', repositoryId: 'rX'))),
        refused(DataRefusalCode.notFound, 'rX'),
      );
      expect(
        () => app.handle(
          SessionCreate(
            Session(
              id: 's4',
              repositoryId: 'r1',
              agentInstallationId: 'aX',
              title: 'Work',
              useWorktree: false,
              status: SessionStatus.created,
              createdAt: now,
            ),
          ),
        ),
        refused(DataRefusalCode.notFound, 'aX'),
      );
      expect(
        () => app.handle(SessionCreate(row(id: 's5', parentSessionId: 'sX'))),
        refused(DataRefusalCode.notFound, 'sX'),
      );
      expect(
        () => app.handle(
          SessionCreate(row(id: 's6'), repositories: const ['r3']),
        ),
        refused(DataRefusalCode.invalid, 'same project'),
      );
    });

    test('a title a person typed is theirs; blank or a placeholder is '
        'never, so the agent may still name it', () {
      final typed = app
          .handle(
            SessionCreate(row(title: 'phone 1c').copyWith(titleByUser: true)),
          )
          .value;
      expect(typed.titleByUser, isTrue);
      expect(snapshot().sessions.single.titleByUser, isTrue);
      for (final (id, title) in [('s2', 'New session'), ('s3', ' Session ')]) {
        final placeholder = app
            .handle(
              SessionCreate(
                row(id: id, title: title).copyWith(titleByUser: true),
              ),
            )
            .value;
        expect(placeholder.titleByUser, isFalse, reason: title);
      }
      final machine = app.handle(SessionCreate(row(id: 's4'))).value;
      expect(machine.titleByUser, isFalse);
    });

    test('an edit writes only the columns it names, and is told', () {
      app.handle(
        SessionCreate(row().copyWith(paneId: 'pane-1', permissionMode: 'plan')),
      );
      final renamed = app
          .handle(SessionEdit('s1', SessionPatch.rename('New', byUser: true)))
          .value;
      expect(renamed.title, 'New');
      expect(renamed.titleByUser, isTrue);
      expect(renamed.paneId, 'pane-1');
      expect(renamed.permissionMode, 'plan');
      expect((lastTold().single as SessionRowChanged).session.title, 'New');

      final cleared = app
          .handle(
            SessionEdit(
              's1',
              SessionPatch.pane(null).and(SessionPatch.model('')),
            ),
          )
          .value;
      expect(cleared.paneId, isNull);
      expect(cleared.modelId, isNull, reason: "'' is none");
      expect(cleared.title, 'New');
    });

    test('an edit that changes nothing tells nobody', () {
      app.handle(SessionCreate(row()));
      final before = told.length;
      app.handle(SessionEdit('s1', SessionPatch.rename('Work')));
      expect(told, hasLength(before));
    });

    test('a status for a session the server runs is its own to record: '
        'ignored, while the rest of the edit lands', () {
      app.handle(SessionCreate(row(status: SessionStatus.running)));
      running.add('s1');
      final edited = app
          .handle(
            SessionEdit(
              's1',
              SessionPatch.status(
                SessionStatus.failed,
              ).and(SessionPatch.view(SessionView.chat)),
            ),
          )
          .value;
      expect(edited.status, SessionStatus.running);
      expect(edited.view, SessionView.chat);
    });

    test(
      'a status ignored with nothing else in the edit still tells the row '
      'back: the asking copy already shows what it asked, and rolls back',
      () {
        app.handle(SessionCreate(row(status: SessionStatus.running)));
        running.add('s1');
        final before = told.length;
        final reply = app.handle(
          SessionEdit('s1', SessionPatch.status(SessionStatus.cancelled)),
        );
        expect(reply.value.status, SessionStatus.running);
        final back = reply.changes.whereType<SessionRowChanged>().single;
        expect(back.session.status, SessionStatus.running);
        expect(told, hasLength(before + 1));
        expect(
          (lastTold().single as SessionRowChanged).session.status,
          SessionStatus.running,
        );
      },
    );

    test('a blank title and an unknown session are refused', () {
      app.handle(SessionCreate(row()));
      expect(
        () => app.handle(SessionEdit('s1', SessionPatch.rename(' '))),
        refused(DataRefusalCode.invalid),
      );
      expect(
        () => app.handle(SessionEdit('sX', SessionPatch.rename('x'))),
        refused(DataRefusalCode.notFound),
      );
    });

    test('a delete takes the links, the log and the recap with it, and says '
        'so', () {
      app.handle(SessionCreate(row()));
      app.handle(
        SessionEventsAppend([
          SessionEvent(
            sessionId: 's1',
            seq: 0,
            type: 'message.user',
            payload: '{}',
            createdAt: now,
          ),
        ]),
      );
      app.handle(
        RecapWrite(
          SessionRecap(
            sessionId: 's1',
            text: 'done',
            agentId: 'claude-code',
            turnCount: 1,
            writtenAt: now,
          ),
        ),
      );
      app.handle(const SessionDelete('s1'));
      expect(lastTold(), [
        isA<SessionRowRemoved>(),
        isA<SessionLinksChanged>().having((c) => c.links, 'links', isEmpty),
        isA<RecapRemoved>(),
      ]);
      final after = snapshot();
      expect(after.sessions, isEmpty);
      expect(after.links, isEmpty);
      expect(after.recaps, isEmpty);
      expect(app.handle(const SessionEvents('s1')).value, isEmpty);
    });
  });

  group('checkouts a session spans', () {
    test('only its own project\'s, and never the primary taken off', () {
      app.handle(SessionCreate(row()));
      expect(
        app
            .handle(const SessionLinkAdd(sessionId: 's1', repositoryId: 'r2'))
            .value,
        hasLength(2),
      );
      expect(
        () => app.handle(
          const SessionLinkAdd(sessionId: 's1', repositoryId: 'r3'),
        ),
        refused(DataRefusalCode.invalid, 'same project'),
      );
      final kept = app
          .handle(const SessionLinkRemove(sessionId: 's1', repositoryId: 'r1'))
          .value;
      expect(kept, hasLength(2), reason: 'the primary stays');
      final left = app
          .handle(const SessionLinkRemove(sessionId: 's1', repositoryId: 'r2'))
          .value;
      expect([for (final l in left) l.repositoryId], ['r1']);
    });
  });

  group('records', () {
    test('events are numbered per session, in the order sent', () {
      app.handle(SessionCreate(row()));
      SessionEvent event(String type) => SessionEvent(
        sessionId: 's1',
        seq: 99,
        type: type,
        payload: '{}',
        createdAt: now,
      );
      final stored = app
          .handle(SessionEventsAppend([event('a'), event('b')]))
          .value;
      expect([for (final e in stored) e.seq], [0, 1]);
      expect(app.handle(SessionEventsAppend([event('c')])).value.single.seq, 2);
      expect(
        [for (final e in app.handle(const SessionEvents('s1')).value) e.type],
        ['a', 'b', 'c'],
      );
      expect(app.handle(const SessionEventsLatest(['s1'])).value, now);
      expect(
        () => app.handle(
          SessionEventsAppend([
            SessionEvent(
              sessionId: 'sX',
              seq: 0,
              type: 'a',
              payload: '{}',
              createdAt: now,
            ),
          ]),
        ),
        refused(DataRefusalCode.notFound),
      );
    });

    test('decisions are sequenced and told; a blank one is refused', () {
      app.handle(SessionCreate(row()));
      DecisionRecord decision(String summary) => DecisionRecord(
        sessionId: 's1',
        kind: DecisionKind.constraintAccepted,
        summary: summary,
        origin: DecisionOrigin.userEntry,
        recordedAt: now,
      );
      final first = app.handle(DecisionAppend(decision('one'))).value;
      final second = app.handle(DecisionAppend(decision('two'))).value;
      expect([first.sequence, second.sequence], [1, 2]);
      expect((lastTold().single as DecisionRecorded).decision.summary, 'two');
      expect(
        () => app.handle(DecisionAppend(decision('  '))),
        refused(DataRefusalCode.invalid),
      );
    });

    test('relays are counted between two sessions since a time', () {
      app.handle(SessionCreate(row()));
      app.handle(SessionCreate(row(id: 's2')));
      for (var i = 0; i < 3; i++) {
        app.handle(
          RelayRecord(
            SessionRelay(
              fromSessionId: 's2',
              toSessionId: 's1',
              text: 'm$i',
              at: now.add(Duration(minutes: i)),
            ),
          ),
        );
      }
      expect(
        app
            .handle(
              RelayCount(
                fromSessionId: 's2',
                toSessionId: 's1',
                since: now.add(const Duration(minutes: 1)),
              ),
            )
            .value,
        2,
      );
      final page = app.handle(const RelaysTo('s1', 2)).value;
      expect([for (final r in page.relays) r.text], ['m1', 'm2']);
      expect(page.total, 3);
    });

    test('one open follow-up per session, raised at the server\'s clock; '
        'resolving twice keeps the first', () {
      FollowUp asked() => FollowUp(
        sessionId: 's1',
        reason: FollowUpReason.endedInFailure,
        ending: SessionEnding.failed,
        raisedAt: DateTime.utc(2000),
      );
      final raised = app.handle(FollowUpRaise(asked())).value!;
      expect(raised.raisedAt, now);
      expect(app.handle(FollowUpRaise(asked())).value, isNull);
      final resolved = app
          .handle(FollowUpResolve(raised.id!, FollowUpResolution.dismissed))
          .value!;
      expect(resolved.resolution, FollowUpResolution.dismissed);
      final again = app
          .handle(FollowUpResolve(raised.id!, FollowUpResolution.sessionGone))
          .value!;
      expect(again.resolution, FollowUpResolution.dismissed);
    });
  });

  group('a failed start', () {
    FollowUp failed(String sessionId) => FollowUp(
      sessionId: sessionId,
      reason: FollowUpReason.endedInFailure,
      ending: SessionEnding.failed,
      raisedAt: now,
    );

    FollowUp followUpOf(String sessionId) =>
        snapshot().followUps.where((f) => f.sessionId == sessionId).single;

    test('is retired as carried forward once another session starts in the '
        'same place, and said so', () {
      app.handle(SessionCreate(row(id: 'f1', title: 'New session')));
      app.handle(FollowUpRaise(failed('f1')));

      app.handle(SessionCreate(row(id: 's2')));

      expect(followUpOf('f1').resolution, FollowUpResolution.carriedForward);
      expect(
        lastTold().whereType<FollowUpChanged>().single.followUp.sessionId,
        'f1',
      );
    });

    test('is retired by a session the server starts itself, when it '
        'announces the row', () {
      app.handle(SessionCreate(row(id: 'f1', title: 'New session')));
      app.handle(FollowUpRaise(failed('f1')));

      SessionDao(db).insertWithPrimaryRepository(row(id: 's2'));
      service.announceSessions(['s2']);

      expect(followUpOf('f1').resolution, FollowUpResolution.carriedForward);
      expect(lastTold().whereType<FollowUpChanged>(), hasLength(1));
    });

    test('is not retired by a session that was already there before it '
        'failed', () {
      app.handle(SessionCreate(row(id: 'f1', title: 'New session')));
      SessionDao(db).insertWithPrimaryRepository(
        row(
          id: 'old',
        ).copyWith(createdAt: now.subtract(const Duration(hours: 1))),
      );
      app.handle(FollowUpRaise(failed('f1')));

      service.announceSessions(['old']);

      expect(followUpOf('f1').isOpen, isTrue);
    });

    test('stays while nothing new starts there: a fresh failure is still '
        'news', () {
      app.handle(SessionCreate(row(id: 'f1', title: 'New session')));
      app.handle(FollowUpRaise(failed('f1')));

      app.handle(SessionCreate(row(id: 's2', repositoryId: 'r3')));

      expect(followUpOf('f1').isOpen, isTrue);
    });

    test('a session that got as far as a name keeps its follow-up: it may '
        'have left work behind', () {
      app.handle(SessionCreate(row(id: 'f1', title: 'Refactor the parser')));
      app.handle(FollowUpRaise(failed('f1')));

      app.handle(SessionCreate(row(id: 's2')));

      expect(followUpOf('f1').isOpen, isTrue);
    });
  });

  group('imported history', () {
    ImportedSession imported({String id = 'i1', String externalId = 'ext'}) =>
        ImportedSession(
          id: id,
          repositoryId: 'r1',
          cli: 'claude-code',
          externalId: externalId,
          environmentId: 'windows',
          filePath: 'f',
          storeHome: 'h',
          isSubagent: false,
          preview: 'hi',
          createdAt: now,
        );

    test(
      'a conversation is imported once, never over a row that records it',
      () {
        expect(app.handle(ImportedAdd(imported())).value, isTrue);
        expect(app.handle(ImportedAdd(imported(id: 'i2'))).value, isFalse);
        app.handle(SessionCreate(row(externalSessionId: 'ext-2')));
        expect(
          app
              .handle(ImportedAdd(imported(id: 'i3', externalId: 'ext-2')))
              .value,
          isFalse,
        );
        app.handle(const ImportedRename(id: 'i1', title: 'Named'));
        expect(snapshot().imported.single.title, 'Named');
        app.handle(const ImportedDelete('i1'));
        expect(snapshot().imported, isEmpty);
      },
    );
  });

  test('a project deleted takes its sessions and history, told as changes', () {
    app.handle(SessionCreate(row()));
    app.handle(SessionCreate(row(id: 's3', repositoryId: 'r3')));
    app.handle(SessionLinkAdd(sessionId: 's3', repositoryId: 'r3'));
    app.handle(
      ImportedAdd(
        ImportedSession(
          id: 'i1',
          repositoryId: 'r1',
          cli: 'claude-code',
          externalId: 'ext',
          environmentId: 'windows',
          filePath: 'f',
          storeHome: 'h',
          isSubagent: false,
          preview: '',
          createdAt: now,
        ),
      ),
    );
    app.handle(const ProjectDelete('p1'));
    final changes = lastTold();
    expect(changes.whereType<SessionRowRemoved>().map((c) => c.id), ['s1']);
    expect(changes.whereType<ImportedRemoved>().map((c) => c.id), ['i1']);
    expect([for (final s in snapshot().sessions) s.id], ['s3']);
  });

  test('what the server writes itself is told to every client', () {
    app.handle(SessionCreate(row()));
    db.execute("UPDATE sessions SET status = 'running' WHERE id = 's1';");
    service.announceSessions(['s1', 'gone']);
    expect(lastTold(), [
      isA<SessionRowChanged>().having(
        (c) => c.session.status,
        'status',
        SessionStatus.running,
      ),
      isA<SessionLinksChanged>(),
      isA<SessionRowRemoved>().having((c) => c.id, 'id', 'gone'),
    ]);
  });

  test('every sessions request and change travels through JSON unchanged', () {
    final session = row().copyWith(
      worktree: const EnvironmentPath(environmentId: 'windows', path: 'wt'),
      permissionMode: 'plan',
    );
    final request =
        DataEnvelope.readRequest(
              DataEnvelope.request(
                1,
                SessionEdit(
                  's1',
                  SessionPatch.directory(
                    null,
                  ).and(SessionPatch.rename('x', byUser: true)),
                ),
              ),
            ).request!
            as SessionEdit;
    expect(request.patch.applyTo(session).title, 'x');
    expect(request.patch.applyTo(session).titleByUser, isTrue);
    final created =
        DataEnvelope.readRequest(
              DataEnvelope.request(2, SessionCreate(session)),
            ).request!
            as SessionCreate;
    expect(created.session, session);
    final batch = DataChanges.fromJson(
      DataChanges(1, [SessionRowChanged(session)]).toJson(),
    );
    expect((batch.changes.single as SessionRowChanged).session, session);
  });
}
