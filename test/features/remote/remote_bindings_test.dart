/// The production bindings against a real container: the same DAOs, the same
/// attention state and the same transcript mapping the desktop reads —
/// with the two probe-shaped lookups stubbed, so nothing spawns a process.
library;

import 'dart:convert';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_installation.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:karmashala/src/features/cli_detection/domain/imported_session.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/session_attention.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/projects/domain/project.dart';
import 'package:karmashala/src/features/remote/application/host_bindings.dart';
import 'package:karmashala/src/features/remote/application/remote_bindings.dart';
import 'package:karmashala/src/features/remote/data/paired_device_dao.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/repositories/domain/repository.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_event_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_attribution.dart';
import 'package:karmashala/src/features/sessions/domain/session_event.dart';
import 'package:karmashala/src/features/sessions/domain/session_event_types.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../terminal/fake_instance.dart';
import 'fake_bindings.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  final now = DateTime.utc(2026, 8, 31, 10);

  setUp(() {
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        // The two lookups whose production path is a probe (git/gh, the
        // status sources). Everything else is the real wiring.
        remoteDeliveryStageProvider.overrideWithValue(
          (sessionId) async => 'working',
        ),
        remoteApprovalEvidenceProvider.overrideWithValue(
          (sessionId) async => null,
        ),
        remoteSessionPresenceProvider.overrideWithValue(
          (sessionId) =>
              (note: 'running here', lastSeen: DateTime.utc(2026, 8, 31, 9)),
        ),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  EnvironmentPath path(String p) =>
      EnvironmentPath(environmentId: 'windows', path: p);

  void seedWorkspace() {
    ExecutionEnvironmentDao(db).upsert(
      ExecutionEnvironment(
        id: 'windows',
        kind: EnvironmentKind.windowsNative,
        name: 'Windows',
        createdAt: now,
      ),
    );
    ProjectDao(db).insert(
      Project(id: 'p1', name: 'Proj', root: path(r'C:\work'), createdAt: now),
    );
    RepositoryDao(db).insert(
      Repository(
        id: 'r1',
        projectId: 'p1',
        name: 'proj-repo',
        path: path(r'C:\work\proj'),
        createdAt: now,
      ),
    );
    AgentInstallationDao(db).insert(
      AgentInstallation(
        id: 'i1',
        agentId: 'mystery',
        executable: path(r'C:\bin\mystery.exe'),
        createdAt: now,
      ),
    );
  }

  void seedSession(
    String id, {
    String title = 'Fix the build',
    String? parentSessionId,
  }) {
    SessionDao(db).insert(
      Session(
        id: id,
        repositoryId: 'r1',
        agentInstallationId: 'i1',
        title: title,
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: now,
        surface: SessionSurface.external,
        parentSessionId: parentSessionId,
      ),
    );
  }

  void appendEvent(String sessionId, String type, Map<String, Object?> data) {
    SessionEventDao(db).append(
      SessionEvent(
        sessionId: sessionId,
        seq: 0,
        type: type,
        payload: jsonEncode(data),
        createdAt: now,
      ),
    );
  }

  test('sessions carry their repository name and live attention', () {
    seedWorkspace();
    seedSession('s1');
    container.read(sessionAttentionProvider.notifier).set([
      SessionAttention(
        session: const WatchedSession(
          key: AgentSessionKey('mystery', 'ext1'),
          label: 'Fix the build',
          openId: 's1',
          imported: false,
        ),
        kind: AttentionKind.needsInput,
      ),
    ]);

    final bindings = container.read(remoteHostBindingsProvider);
    final sessions = bindings.listSessions();

    expect(sessions, hasLength(1));
    expect(sessions.single.title, 'Fix the build');
    expect(sessions.single.status, 'running');
    expect(sessions.single.repositoryName, 'proj-repo');
    expect(sessions.single.attention, 'needs_approval');
    // The desktop card's own wording, built host-side from typed fields:
    // registry display name (raw id for an unknown agent) plus the status.
    expect(sessions.single.agentLabel, 'mystery  ·  running');
    expect(sessions.single.whereabouts, 'running here');
    expect(sessions.single.lastActivityAt, '2026-08-31T09:00:00.000Z');
    expect(sessions.single.imported, isFalse);
    expect(bindings.sessionById('s1'), isNotNull);
    expect(bindings.sessionById('nope'), isNull);
  });

  test('imported CLI sessions are listed, flagged, and read-only', () async {
    seedWorkspace();
    seedSession('s1');
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'imp1',
        repositoryId: 'r1',
        cli: 'mystery',
        externalId: 'x1',
        environmentId: 'windows',
        filePath: r'C:\nowhere\imp1.jsonl',
        storeHome: r'C:\nowhere',
        isSubagent: false,
        preview: 'an old conversation',
        title: 'Old CLI chat',
        createdAt: now,
        updatedAt: DateTime.utc(2026, 8, 31, 8),
      ),
    );
    container.read(sessionAttentionProvider.notifier).set([
      SessionAttention(
        session: const WatchedSession(
          key: AgentSessionKey('mystery', 'x1'),
          label: 'Old CLI chat',
          openId: 'imp1',
          imported: true,
        ),
        kind: AttentionKind.failed,
      ),
    ]);

    final bindings = container.read(remoteHostBindingsProvider);
    final sessions = bindings.listSessions();

    expect(sessions, hasLength(2));
    final imported = sessions.singleWhere((s) => s.imported);
    expect(imported.sessionId, 'imp1');
    expect(imported.title, 'Old CLI chat');
    // The desktop's own imported wording; the raw status word degrades
    // honestly on an old companion that shows it as the label.
    expect(imported.agentLabel, 'mystery  ·  imported');
    expect(imported.status, 'imported');
    expect(imported.repositoryName, 'proj-repo');
    // The store file's mtime, never our poll time.
    expect(imported.lastActivityAt, '2026-08-31T08:00:00.000Z');
    // Imported attention rows match only imported ids — never s1's.
    expect(imported.attention, 'failed');
    expect(sessions.singleWhere((s) => !s.imported).attention, isNull);

    // Listed and subscribable, but never steerable.
    expect(bindings.sessionById('imp1')?.imported, isTrue);
    await expectLater(
      bindings.sendPrompt('imp1', 'hi'),
      throwsA(
        isA<RemoteApiRefusal>().having(
          (r) => r.code,
          'code',
          ErrorCode.badRequest,
        ),
      ),
    );
    await expectLater(
      bindings.answerApproval('imp1', 'approve'),
      throwsA(
        isA<RemoteApiRefusal>().having(
          (r) => r.code,
          'code',
          ErrorCode.badRequest,
        ),
      ),
    );
  });

  test('an imported transcript whose store file is gone reads empty, '
      'never throws', () async {
    seedWorkspace();
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'imp2',
        repositoryId: 'r1',
        cli: 'mystery',
        externalId: 'x2',
        environmentId: 'windows',
        filePath: r'C:\nowhere\gone.jsonl',
        storeHome: r'C:\nowhere',
        isSubagent: false,
        preview: 'gone',
        createdAt: now,
      ),
    );

    final bindings = container.read(remoteHostBindingsProvider);
    final page = await bindings.transcriptFor('imp2');

    expect(page.sessionId, 'imp2');
    expect(page.messages, isEmpty);
  });

  test('the event-log transcript mirrors the desktop chat mapping', () async {
    seedWorkspace();
    seedSession('s1');
    appendEvent('s1', SessionEventTypes.sessionStarted, {'title': 'x'});
    appendEvent('s1', SessionEventTypes.userMessage, {'text': 'hello'});
    appendEvent('s1', SessionEventTypes.agentMessage, {'text': 'hi there'});
    appendEvent('s1', SessionEventTypes.agentStatus, {'noise': true});
    appendEvent('s1', SessionEventTypes.error, {'text': 'boom'});
    appendEvent('s1', SessionEventTypes.sessionCancelled, {});

    final bindings = container.read(remoteHostBindingsProvider);
    final page = await bindings.transcriptFor('s1');

    expect(
      [for (final m in page.messages) (m.role, m.text)],
      [
        ('user', 'hello'),
        ('agent', 'hi there'),
        ('error', 'boom'),
        ('tool', 'Session ended.'),
      ],
    );
    expect(page.cursor, 4);
  });

  test('attribution is rebuilt from typed fields and stripped whole', () async {
    seedWorkspace();
    seedSession('parent', title: r'Fix [urgent] crash');
    seedSession('child', parentSessionId: 'parent');
    final attribution = const SessionAttribution(
      sessionId: 'parent',
      title: r'Fix [urgent] crash',
    );
    appendEvent('child', SessionEventTypes.userMessage, {
      'text': attribution.render('do the thing'),
    });
    // A prefix built from a title the parent no longer has must NOT be
    // half-stripped — the fail-safe direction of the dray constraint.
    appendEvent('child', SessionEventTypes.userMessage, {
      'text':
          '[message from the Karmashala session "Old title" (parent)]\n\nkeep me whole',
    });

    final bindings = container.read(remoteHostBindingsProvider);
    final page = await bindings.transcriptFor('child');

    expect(page.messages.first.text, 'do the thing');
    expect(
      page.messages.last.text,
      '[message from the Karmashala session "Old title" (parent)]\n\nkeep me whole',
    );
  });

  test('a transcript for a missing session is a not_found refusal', () {
    seedWorkspace();
    final bindings = container.read(remoteHostBindingsProvider);

    expect(
      () => bindings.transcriptFor('ghost'),
      throwsA(
        isA<RemoteApiRefusal>().having(
          (r) => r.code,
          'code',
          ErrorCode.notFound,
        ),
      ),
    );
  });

  test('an agent that names no keys cannot be answered for', () async {
    seedWorkspace();
    seedSession('s1');
    final bindings = container.read(remoteHostBindingsProvider);

    // `mystery` is not in the registry, so its approval rules are empty —
    // pressing a guessed key on another program is exactly what Loop 49
    // refused to do, and the remote path refuses it the same way.
    await expectLater(
      bindings.answerApproval('s1', 'approve'),
      throwsA(
        isA<RemoteApiRefusal>().having(
          (r) => r.code,
          'code',
          ErrorCode.badRequest,
        ),
      ),
    );
    await expectLater(
      bindings.answerApproval('ghost', 'approve'),
      throwsA(
        isA<RemoteApiRefusal>().having(
          (r) => r.code,
          'code',
          ErrorCode.notFound,
        ),
      ),
    );
  });

  // --- A conversation the desktop has reconciled ----------------------------
  //
  // The owner opened a session on the phone and got "a session that's not
  // running": read-only CLI history for a conversation that was live in a pane
  // on the desktop. `sessions` and `imported_sessions` can each hold a record
  // of one conversation and `ImportedSessionDao` resolves the tie — a
  // conversation with a native row is *superseded*. The list already obeyed
  // that (every list read there filters); resolving an id did not, so a phone
  // holding the imported id — from a list fetched before attribution wrote the
  // conversation id onto the native row — was answered with the history.

  void seedImported(
    String id, {
    required String externalId,
    String title = 'Old CLI chat',
  }) {
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: id,
        repositoryId: 'r1',
        cli: 'mystery',
        externalId: externalId,
        environmentId: 'windows',
        filePath: 'C:\\nowhere\\$id.jsonl',
        storeHome: r'C:\nowhere',
        isSubagent: false,
        preview: 'an old conversation',
        title: title,
        createdAt: now,
        updatedAt: DateTime.utc(2026, 8, 31, 8),
      ),
    );
  }

  /// Writes the conversation id onto a native row, which is what
  /// `LaunchedSessionAttributionService` does on a store sweep — the moment
  /// the imported record becomes superseded.
  void attribute(String sessionId, String externalId) =>
      SessionDao(db).updateExternalSessionId(sessionId, externalId);

  group('a conversation the desktop has reconciled', () {
    test('is listed once, as the live row', () {
      seedWorkspace();
      seedImported('imp1', externalId: 'x1');
      seedSession('s1', title: 'Old CLI chat');
      attribute('s1', 'x1');

      final rows = container.read(remoteHostBindingsProvider).listSessions();

      expect(rows, hasLength(1));
      expect(rows.single.sessionId, 's1');
      expect(rows.single.imported, isFalse);
    });

    test('opens on the live row when the phone holds the imported id', () async {
      seedWorkspace();
      seedImported('imp1', externalId: 'x1');
      seedSession('s1', title: 'Old CLI chat');
      attribute('s1', 'x1');
      appendEvent('s1', SessionEventTypes.agentMessage, {'text': 'still here'});

      final bindings = container.read(remoteHostBindingsProvider);

      // The stale id the phone is holding resolves to the running session.
      final snapshot = bindings.sessionById('imp1');
      expect(snapshot, isNotNull);
      expect(snapshot!.sessionId, 's1');
      expect(snapshot.imported, isFalse);
      expect(snapshot.status, 'running');

      // And so does everything that takes a session id.
      final page = await bindings.transcriptFor('imp1');
      expect([for (final m in page.messages) m.text], ['still here']);

      // Not "imported from the CLI — read-only here": this reaches the live
      // row and stops on the agent's own approval rules, like `s1` does.
      await expectLater(
        bindings.answerApproval('imp1', 'approve'),
        throwsA(
          isA<RemoteApiRefusal>().having(
            (r) => r.message,
            'message',
            contains('names no way to approve'),
          ),
        ),
      );
    });

    test('history with no native row is still listed and still read-only',
        () async {
      seedWorkspace();
      seedImported('imp2', externalId: 'x2');

      final bindings = container.read(remoteHostBindingsProvider);
      final rows = bindings.listSessions();

      expect(rows, hasLength(1));
      expect(rows.single.sessionId, 'imp2');
      expect(rows.single.imported, isTrue);
      expect(bindings.sessionById('imp2')?.imported, isTrue);
      await expectLater(
        bindings.answerApproval('imp2', 'approve'),
        throwsA(
          isA<RemoteApiRefusal>().having(
            (r) => r.message,
            'message',
            contains('imported from the CLI'),
          ),
        ),
      );
    });

    test('a native row with no conversation id yet hides nothing', () {
      // The window `LaunchedSessionAttributionService` exists to close: a
      // Codex row keeps a null id until a store sweep discovers it, and a null
      // id must never be read as "this row represents that history".
      seedWorkspace();
      seedImported('imp3', externalId: 'x3');
      seedSession('s1');

      final bindings = container.read(remoteHostBindingsProvider);
      final rows = bindings.listSessions();

      expect(
        [for (final row in rows) row.sessionId],
        containsAll(<String>['s1', 'imp3']),
      );
      expect(bindings.sessionById('imp3')?.imported, isTrue);
    });
  });

  test('push registration lands on the paired-device row', () async {
    final dao = PairedDeviceDao(db);
    dao.insert(fakeDevice());
    final bindings = container.read(remoteHostBindingsProvider);

    await bindings.registerPush(fakeDevice().id, 'tok3n', 'android');

    final row = dao.getById(fakeDevice().id)!;
    expect(row.pushToken, 'tok3n');
    expect(row.pushPlatform, 'android');
  });
}
