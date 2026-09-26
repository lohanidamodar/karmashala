import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:test/test.dart';

/// Every request survives the envelope as JSON text, as a transport carries
/// it, and so does every answer and change.
void main() {
  final t0 = DateTime.utc(2026, 9, 26, 9, 30);
  final note = Note(
    id: 'n',
    title: 'T',
    body: 'b',
    projectId: 'p',
    sourceSessionId: 's',
    sourceRepositoryId: 'r',
    sourceMessageOrdinal: 3,
    sourceMessageRole: 'user',
    createdAt: t0,
    updatedAt: t0,
  );
  final todo = Todo(id: 't', body: 'b', position: 2, createdAt: t0, doneAt: t0);
  const root = EnvironmentPath(environmentId: 'windows', path: r'C:\src');
  final project = Project(
    id: 'p',
    name: 'Demo',
    root: root,
    createdAt: t0,
    workspaceId: 'w',
    defaultRepositoryId: 'r',
  );
  final checkout = Repository(
    id: 'r',
    projectId: 'p',
    name: 'app',
    path: root,
    createdAt: t0,
    canonicalId: 'github.com/a/b',
  );
  final workspace = Workspace(
    id: 'w',
    name: 'PopupBits',
    description: 'd',
    color: 'teal',
    createdAt: t0,
  );
  const section = StoredSection(
    id: 's',
    name: 'Mine',
    kind: 'manual',
    position: 1,
    collapsed: false,
    members: {'a', 'b'},
  );
  const found = [DiscoveredRepository(name: 'app', path: root)];
  final session = Session(
    id: 's1',
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'Work',
    useWorktree: false,
    status: SessionStatus.running,
    createdAt: t0,
    paneId: 'pane',
    permissionMode: 'plan',
  );
  final imported = ImportedSession(
    id: 'i',
    repositoryId: 'r1',
    cli: 'claude-code',
    externalId: 'conv',
    environmentId: 'windows',
    filePath: 'f',
    storeHome: 'h',
    isSubagent: true,
    preview: 'p',
    title: 'T',
    updatedAt: t0,
    createdAt: t0,
  );

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  final requests = <DataRequest<Object?>>[
    const DataSubscribe(),
    const NotesList(sessionId: 's'),
    const NoteCapture(
      id: 'n',
      body: ' b ',
      title: 't',
      projectId: 'p',
      inheritProject: false,
      sourceSessionId: 's',
      sourceRepositoryId: 'r',
      sourceMessageOrdinal: 1,
      sourceMessageRole: 'assistant',
    ),
    const NoteEdit(id: 'n', body: 'b', title: 't', projectId: 'p'),
    const NoteFile(id: 'n'),
    const NoteDelete('n'),
    const TodosList(),
    const TodoAdd(id: 't', body: 'b', projectOfSession: 's'),
    const TodoSetDone(id: 't', done: true),
    const TodoEdit(id: 't', body: 'b'),
    const TodoFile(id: 't', projectId: 'p'),
    const TodoMove(id: 't', up: false),
    const TodoDelete('t'),
    const TodosClearDone(['a', 'b']),
    const PreferencesGet(),
    const PreferenceSet('k', 'v'),
    const PreferenceRemove('k'),
    const WorkspaceList(),
    const WorkspacePut(id: 'w', workspaceName: 'W', description: 'd'),
    const WorkspaceSetColor(id: 'w', color: 'teal'),
    const WorkspaceDelete('w'),
    const ProjectCreate(
      projectName: 'P',
      root: root,
      workspaceId: 'w',
      found: found,
    ),
    const ProjectUpdate(
      id: 'p',
      projectName: 'Q',
      root: root,
      clearDefaultRepository: true,
      found: found,
    ),
    const ProjectsFile({'p': 'w', 'q': null}),
    const ProjectDelete('p'),
    const ProjectsUsingEnvironment('ssh:h'),
    const CheckoutsAdd(projectId: 'p', found: found, orRoot: false),
    const CheckoutsRetire(['r']),
    const CheckoutsIdentify(path: root, canonicalId: 'x'),
    const SectionPut(section),
    const SectionsReorder(['s', 't']),
    const SectionDelete('s'),
    const SessionsList(),
    SessionCreate(session, repositories: const ['r2']),
    SessionEdit(
      's1',
      SessionPatch.pane(null).and(SessionPatch.rename('x', byUser: true)),
    ),
    const SessionDelete('s1'),
    const SessionLinkAdd(sessionId: 's1', repositoryId: 'r2'),
    const SessionLinkRemove(sessionId: 's1', repositoryId: 'r2'),
    const SessionEvents('s1'),
    const SessionEventsLatest(['s1', 's2']),
    SessionEventsAppend([
      SessionEvent(
        sessionId: 's1',
        seq: 0,
        type: 'message.user',
        payload: '{}',
        createdAt: t0,
      ),
    ]),
    DecisionAppend(
      DecisionRecord(
        sessionId: 's1',
        kind: DecisionKind.constraintAccepted,
        summary: 'x',
        origin: DecisionOrigin.userEntry,
        recordedAt: t0,
      ),
    ),
    RecapWrite(
      SessionRecap(
        sessionId: 's1',
        text: 't',
        agentId: 'claude-code',
        turnCount: 1,
        writtenAt: t0,
      ),
    ),
    const RecapDismiss('s1'),
    RelayRecord(
      SessionRelay(fromSessionId: 'a', toSessionId: 'b', text: 't', at: t0),
    ),
    const RelaysTo('b', 5),
    RelayCount(fromSessionId: 'a', toSessionId: 'b', since: t0),
    FollowUpRaise(
      FollowUp(
        sessionId: 's1',
        reason: FollowUpReason.endedInFailure,
        ending: SessionEnding.failed,
        raisedAt: t0,
      ),
    ),
    const FollowUpResolve(3, FollowUpResolution.dismissed),
    ImportedAdd(imported),
    const ImportedRename(id: 'i', title: 'T'),
    const ImportedDelete('i'),
  ];

  test('sessions changes and snapshots round-trip', () {
    final batch = DataChanges.fromJson(
      overTheWire(
        DataChanges(3, [
          SessionRowChanged(session),
          const SessionRowRemoved('s2'),
          const SessionLinksChanged('s1', [
            SessionRepositoryLink(repositoryId: 'r1', role: 'primary'),
          ]),
          ImportedChanged(imported),
          const ImportedRemoved('i'),
          const DecisionRemoved(4),
          const RecapRemoved('s1'),
        ]).toJson(),
      ),
    );
    expect(batch.changes, hasLength(7));
    expect((batch.changes.first as SessionRowChanged).session, session);
    expect((batch.changes[3] as ImportedChanged).session, imported);
    final snapshot = SessionsSnapshot.fromJson(
      overTheWire(
        SessionsSnapshot(
          sessions: [session],
          links: const {
            's1': [SessionRepositoryLink(repositoryId: 'r1', role: 'primary')],
          },
          imported: [imported],
        ).toJson(),
      ),
    );
    expect(snapshot.sessions.single, session);
    expect(snapshot.links['s1']!.single.isPrimary, isTrue);
    expect(snapshot.imported.single, imported);
  });

  test('every request round-trips with its arguments', () {
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(9, request)),
      );
      expect(read.id, 9);
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request!.kind, request.kind);
      expect(
        read.request!.argumentsToJson(),
        request.argumentsToJson(),
        reason: request.kind,
      );
    }
  });

  test('answers carry typed results, the revision and the changes', () {
    DataReply<R> roundTrip<R>(DataRequest<R> request, R result) =>
        DataEnvelope.readAnswer(
          overTheWire(
            DataEnvelope.answer(4, request, DataReply(result, 17, const [])),
          ),
          request,
        );

    expect(roundTrip(const NotesList(), [note]).value, [note]);
    expect(roundTrip(const TodoMove(id: 't', up: true), [todo]).value, [todo]);
    expect(roundTrip(const TodosClearDone([]), 3).value, 3);
    expect(roundTrip(const PreferencesGet(), {'a': 'b'}).value, {'a': 'b'});
    expect(roundTrip(const TodoAdd(id: 't', body: 'b'), todo).revision, 17);
    final snapshot = roundTrip(
      const WorkspaceList(),
      WorkspaceSnapshot(
        workspaces: [workspace],
        projects: [project],
        repositories: [checkout],
        sections: const [section],
      ),
    ).value;
    expect(snapshot.workspaces, [workspace]);
    expect(snapshot.projects, [project]);
    expect(snapshot.repositories, [checkout]);
    expect(snapshot.sections, [section]);
    final updated = roundTrip(
      const ProjectUpdate(id: 'p'),
      ProjectUpdated(project: project, rebased: [checkout]),
    ).value;
    expect(updated.project, project);
    expect(updated.rebased, [checkout]);
    expect(roundTrip(const CheckoutsRetire(['r']), {'r': 2}).value, {'r': 2});
    expect(roundTrip(const ProjectsUsingEnvironment('e'), ['A']).value, ['A']);

    const delete = ProjectDelete('p');
    final reply = DataEnvelope.readAnswer(
      overTheWire(
        DataEnvelope.answer(
          1,
          delete,
          DataReply(const DataAck(), 3, [
            const ProjectRemoved('p'),
            NoteChanged(note),
          ]),
        ),
      ),
      delete,
    );
    expect(reply.changes, hasLength(2));
    expect((reply.changes.first as ProjectRemoved).id, 'p');
  });

  test('a refusal is thrown typed, with its message', () {
    expect(
      () => DataEnvelope.readAnswer(
        overTheWire(
          DataEnvelope.refusal(4, const DataRefused.notFound('no todo x')),
        ),
        const TodosList(),
      ),
      throwsA(
        isA<DataRefused>()
            .having((r) => r.code, 'code', DataRefusalCode.notFound)
            .having((r) => r.message, 'message', 'no todo x'),
      ),
    );
  });

  test('a misshapen workspace argument is refused, not thrown', () {
    for (final (kind, arguments) in [
      ('projects.create', {'name': 'x', 'root': 'here'}),
      (
        'projects.create',
        {
          'name': 'x',
          'root': environmentPathToJson(root),
          'found': [1],
        },
      ),
      (
        'projects.file',
        {
          'placements': {'p': 3},
        },
      ),
      (
        'sections.put',
        {
          'section': {'id': 's'},
        },
      ),
    ]) {
      expect(
        DataEnvelope.readRequest({
          'id': 1,
          'kind': kind,
          'arguments': arguments,
        }).refusal?.code,
        DataRefusalCode.invalid,
        reason: '$kind $arguments',
      );
    }
  });

  test('an unknown kind or a misshapen argument is refused, not thrown', () {
    expect(
      DataEnvelope.readRequest({'id': 1, 'kind': 'files.delete'}).refusal?.code,
      DataRefusalCode.invalid,
    );
    expect(
      DataEnvelope.readRequest({
        'id': 2,
        'kind': 'todos.setDone',
        'arguments': {'id': 't', 'done': 'yes'},
      }).refusal?.message,
      contains('done'),
    );
  });

  test('an answer this build cannot read is a failure, not a crash', () {
    expect(
      () => DataEnvelope.readAnswer({
        'id': 1,
        'revision': 1,
        'result': 'not a list',
      }, const TodosList()),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.failed,
        ),
      ),
    );
  });

  test('change batches round-trip; an unknown change is skipped', () {
    final batch = DataChanges(5, [
      NoteChanged(note),
      const NoteRemoved('n'),
      TodoChanged(todo),
      const TodoRemoved('t'),
      const PreferenceChanged('k', null),
      WorkspaceChanged(workspace),
      ProjectChanged(project),
      RepositoryChanged(checkout),
      const SectionChanged(section),
      const WorkspaceRemoved('w'),
      const ProjectRemoved('p'),
      const RepositoryRemoved('r'),
      const SectionRemoved('s'),
    ]);
    final json = overTheWire(DataEnvelope.changes(batch));
    (json['changes']! as List).add({'change': 'fromTheFuture'});
    final back = DataEnvelope.readChanges(json);
    expect(back.revision, 5);
    expect(back.changes, hasLength(13));
    expect((back.changes[0] as NoteChanged).note, note);
    expect((back.changes[2] as TodoChanged).todo, todo);
    expect((back.changes[4] as PreferenceChanged).value, isNull);
    expect((back.changes[5] as WorkspaceChanged).workspace, workspace);
    expect((back.changes[6] as ProjectChanged).project, project);
    expect((back.changes[7] as RepositoryChanged).repository, checkout);
    expect((back.changes[8] as SectionChanged).section, section);
    expect(
      [for (final change in back.changes.skip(9)) (change as RowRemoved).id],
      ['w', 'p', 'r', 's'],
    );
  });

  test('reserved preference keys and shapes', () {
    expect(PreferenceKeys.isReserved('remote.host_device_id'), isTrue);
    expect(PreferenceKeys.isReserved('settings.v1'), isFalse);
    expect(PreferenceKeys.keyProblem('has space'), isNotNull);
    expect(PreferenceKeys.keyProblem('ssh.companion_route.abc-1'), isNull);
    expect(PreferenceKeys.valueProblem('x' * (1024 * 1024 + 1)), isNotNull);
  });
}
