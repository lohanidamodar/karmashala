/// The production bindings against a real container: the same DAOs, the same
/// attention state and the same transcript mapping the desktop reads —
/// with the two probe-shaped lookups stubbed, so nothing spawns a process.
library;

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/session_attention.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/projects/domain/project.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/repositories/application/repository_discovery_provider.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala/src/features/remote/application/remote_approval_bindings.dart';
import 'package:karmashala/src/features/remote/application/remote_bindings.dart';
import 'package:karmashala_store/devices.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_menu_answerer.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/sessions/data/session_event_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/events.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala_session/launch.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:path/path.dart' as ph;

import '../terminal/fake_instance.dart';
import 'fake_bindings.dart';
import '../../support/fakes.dart';
import '../../support/temp_directory.dart';

/// The store scan, answered from a map, so nothing here walks the owner's own
/// `~/.claude` — and so an Antigravity session can be given a store that keeps
/// a transcript for it, or one that does not.
class _FixedLocator implements SessionTranscriptLocator {
  final paths = <String, String>{};

  @override
  Future<String?> locate({
    required String agentId,
    required String externalSessionId,
  }) async => paths['$agentId/$externalSessionId'];

  @override
  Future<Map<String, String>> index() async => paths;
}

void main() {
  late AppDatabase db;
  late _FixedLocator locator;
  late ProviderContainer container;
  late FakeRepositoryDiscoveryService discovery;
  final now = DateTime.utc(2026, 8, 31, 10);

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(
      ExecutionEnvironment(
        id: localHostEnvironmentId,
        kind: EnvironmentKind.windowsNative,
        name: 'Windows',
        createdAt: now,
      ),
    );
    discovery = FakeRepositoryDiscoveryService();
    locator = _FixedLocator();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        sessionTranscriptLocatorProvider.overrideWithValue(locator),
        repositoryDiscoveryServiceProvider.overrideWithValue(discovery),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
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

  Future<Directory> tempFolder() async {
    final folder = await Directory.systemTemp.createTemp('karmashala-remote-');
    addTearDown(() => folder.delete(recursive: true));
    return folder;
  }

  test('project add rejects unsafe paths without writing a project', () async {
    final bindings = container.read(remoteHostBindingsProvider);
    for (final path in [
      'relative-folder',
      '${Directory.systemTemp.path}\\does-not-exist-karmashala',
      '${Directory.systemTemp.path}\\bad\nname',
      r'\\server\share\project',
    ]) {
      await expectLater(
        bindings.addProject('Project', path),
        throwsA(isA<RemoteApiRefusal>()),
      );
    }
    expect(ProjectDao(db).getAll(), isEmpty);
  });

  test('project add uses a real folder and refreshes controller', () async {
    final folder = await tempFolder();
    final bindings = container.read(remoteHostBindingsProvider);
    final first = await bindings.addProject('Workspace', folder.path);
    expect(first.path, folder.resolveSymbolicLinksSync());
    expect(container.read(projectsControllerProvider), hasLength(1));
    final second = await bindings.addProject('Renamed', folder.path);
    expect(second.projectId, first.projectId);
    expect(ProjectDao(db).getAll(), hasLength(1));
  });

  test('same in-flight path dedupes and a failed path can be retried', () async {
    final folder = await tempFolder();
    final gate = Completer<void>();
    final gatedImport = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        repositoryDiscoveryServiceProvider.overrideWithValue(discovery),
        autoImportRunnerProvider.overrideWithValue(
          (_) => gate.future.then((_) => const ImportSummary()),
        ),
      ],
    );
    addTearDown(gatedImport.dispose);
    final bindings = gatedImport.read(remoteHostBindingsProvider);
    final a = bindings.addProject('A', folder.path);
    await Future<void>.delayed(Duration.zero);
    final b = bindings.addProject('B', folder.path);
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    final results = await Future.wait([a, b]);
    expect(results[0].projectId, results[1].projectId);
    expect(ProjectDao(db).getAll(), hasLength(1));

    final missing = Directory(
      '${Directory.systemTemp.path}\\remote-retry-${DateTime.now().microsecondsSinceEpoch}',
    );
    await expectLater(
      bindings.addProject('Retry', missing.path),
      throwsA(isA<RemoteApiRefusal>()),
    );
    await missing.create(recursive: true);
    addTearDown(() => missing.delete(recursive: true));
    expect((await bindings.addProject('Retry', missing.path)).name, 'Retry');
  });

  test(
    'native resume launches a stopped row with its original conversation and directory',
    () async {
    seedWorkspace();
    final bindings = container.read(remoteHostBindingsProvider);
    await expectLater(
      bindings.resumeSession('s1'),
      throwsA(isA<RemoteApiRefusal>()),
    );
    final launcher = container.read(sessionLauncherProvider);
    final workFolder = await tempFolder();
    final workDir = EnvironmentPath(
      environmentId: 'windows',
      path: workFolder.path,
    );
    final resumableInstallation = AgentInstallation(
      id: 'i2',
      agentId: 'codex',
      executable: path(r'C:\bin\codex.exe'),
      createdAt: now,
    );
    AgentInstallationDao(db).insert(resumableInstallation);
    final result = await launcher.launch(
      SessionLaunchRequest(
        repository: RepositoryDao(db).getById('r1')!,
        installation: resumableInstallation,
        title: 'Active',
        purpose: SessionPurpose.newSession,
        workingDirectory: workDir,
        permissionOverride: PermissionSelection.parse(
          'approval=on-request;sandbox=bypass-all',
        ),
      ),
    );
    final original = result.session.id;
    SessionDao(db).updateExternalSessionId(original, 'external-1');
    final paneId = SessionDao(db).getById(original)!.paneId!;
    container.read(terminalSessionsControllerProvider.notifier).endSession(paneId);
    final resumed = await bindings.resumeSession(original);
    expect(resumed.sessionId, result.session.id);
    expect(SessionDao(db).getAll(), hasLength(1));
    final resumedRow = SessionDao(db).getById(original)!;
    expect(resumedRow.externalSessionId, 'external-1');
    expect(resumedRow.permissionMode, 'approval=on-request;sandbox=bypass-all');
    expect(resumedRow.workingDirectory, workDir);
    final resumedPane = resumedRow.paneId!;
    final instance = container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(resumedPane)!;
    expect(instance.agentLaunch?.arguments, contains('external-1'));
    expect(
      instance.agentLaunch?.arguments,
      contains('--dangerously-bypass-approvals-and-sandbox'),
    );
    expect(instance.agentLaunch?.workingDirectory, workDir.path);
    final again = await bindings.resumeSession(original);
    expect(again.sessionId, original);
    expect(SessionDao(db).getAll(), hasLength(1));
    expect(SessionDao(db).getById(original)!.paneId, resumedPane);
    expect(
      container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(resumedPane),
      same(instance),
    );
    },
  );

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

  group('what a file sent to one session may be', () {
    /// Points `i1` at [agentId], running in [environmentId]. The agent's *own*
    /// environment is what decides this, not the checkout's: the executable is
    /// the thing that has to be able to open the path.
    void installAgent(String agentId, {String environmentId = 'windows'}) {
      // `seedWorkspace` already put `mystery` under this id.
      AgentInstallationDao(db).delete('i1');
      AgentInstallationDao(db).insert(
        AgentInstallation(
          id: 'i1',
          agentId: agentId,
          executable: EnvironmentPath(
            environmentId: environmentId,
            path: '/usr/bin/$agentId',
          ),
          createdAt: now,
        ),
      );
    }

    RemoteAttachmentSupport? supportFor(String sessionId) => container
        .read(remoteHostBindingsProvider)
        .sessionById(sessionId)
        ?.attachments;

    test('a Claude Code session on this machine takes a picture', () {
      seedWorkspace();
      installAgent('claudeCode');
      seedSession('s1');

      final support = supportFor('s1')!;

      expect(support.allowsAnything, isTrue);
      expect(support.mediaTypes, contains('image/jpeg'));
      expect(support.maxBytes, kMaxAttachmentBytes);
      expect(support.refusal, isNull);
    });

    test('the same agent over SSH does not, and the row says why', () {
      seedWorkspace();
      ExecutionEnvironmentDao(db).upsert(
        ExecutionEnvironment(
          id: 'buildbox',
          kind: EnvironmentKind.ssh,
          name: 'build-box',
          createdAt: now,
        ),
      );
      installAgent('claudeCode', environmentId: 'buildbox');
      seedSession('s1');

      final support = supportFor('s1')!;

      expect(support.allowsAnything, isFalse);
      expect(
        support.refusal,
        contains('another machine'),
        reason: 'the agent has its own filesystem; a path written here names '
            'nothing there — and that is nothing to do with the CLI',
      );
    });

    test('an agent that cannot be handed one carries its own sentence', () {
      seedWorkspace();
      installAgent('codex');
      seedSession('s1');

      expect(supportFor('s1')!.allowsAnything, isFalse);
      expect(supportFor('s1')!.refusal, contains('--image'));
    });

    test('an agent nobody has written anything about is refused too', () {
      seedWorkspace();
      seedSession('s1');

      // `seedWorkspace` installs `mystery`, which is in no registry.
      expect(supportFor('s1')!.allowsAnything, isFalse);
      expect(supportFor('s1')!.refusal, isNotEmpty);
    });

    test('imported history says it is read-only rather than saying nothing',
        () async {
      seedWorkspace();
      installAgent('claudeCode');
      ImportedSessionDao(db).insertIfAbsent(
        ImportedSession(
          id: 'imp1',
          repositoryId: 'r1',
          cli: 'claudeCode',
          externalId: 'x1',
          environmentId: 'windows',
          filePath: r'C:\nowhere\imp1.jsonl',
          storeHome: r'C:\nowhere',
          isSubagent: false,
          preview: 'an old conversation',
          title: 'Old CLI chat',
          createdAt: now,
        ),
      );

      final support = supportFor('imp1')!;

      expect(support.allowsAnything, isFalse);
      expect(support.refusal, contains('read-only'));
    });
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
    final page = (await bindings.transcriptFor('imp2')).page;

    expect(page.sessionId, 'imp2');
    expect(page.messages, isEmpty);
  });

  // --- Which nothing it is ------------------------------------------------
  //
  // "I have a running antigravity session and in the mobile companion app it
  // shows running, but when I open it, it doesn't show any transcript." What
  // was broken is that the host knew why and sent `[]`, which is also what a
  // session that has not spoken yet sends, so the phone had to hedge across
  // both and drew a welcome screen over the answer.
  //
  // **Which nothing it is is read per session now**, not per agent: the same
  // Antigravity store keeps a readable JSONL transcript for every conversation
  // on one install here and for none on the other, so both answers below are
  // reachable for the same agent and the wire has to carry the right one.
  group('a transcript page says why it is empty', () {
    void seedPaneSession(String id, {required String agentId}) {
      AgentInstallationDao(db).insert(
        AgentInstallation(
          id: 'i-$agentId',
          agentId: agentId,
          executable: path('C:\\bin\\$agentId.exe'),
          createdAt: now,
        ),
      );
      SessionDao(db).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'i-$agentId',
          title: 'Running now',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: now,
          // A PTY-hosted session renders from the agent's own record, which
          // is the path that can refuse.
          surface: SessionSurface.pane,
          externalSessionId: 'ext-$id',
        ),
      );
    }

    /// A store that holds this conversation's record and no transcript beside
    /// it — the Windows Antigravity install exactly, whose one brain directory
    /// is empty. Nothing is written: the reading is about a file's absence.
    void storeKeepsNoTranscript(String sessionId) {
      locator.paths['antigravity/ext-$sessionId'] = ph.join(
        r'C:\store',
        'conversations',
        'ext-$sessionId.db',
      );
    }

    test('a store that keeps no transcript for this session is the reason',
        () async {
      seedWorkspace();
      seedPaneSession('s-anti', agentId: 'antigravity');
      storeKeepsNoTranscript('s-anti');

      final bindings = container.read(remoteHostBindingsProvider);
      final page = (await bindings.transcriptFor('s-anti')).page;

      expect(page.messages, isEmpty);
      // About this conversation, not about Antigravity: the sibling test below
      // is the store-wide refusal, and they are two different sentences on the
      // phone.
      expect(page.absence, RemoteTranscriptAbsence.noTranscriptFile);
      // The fact survives the round trip a phone actually reads it through.
      expect(
        RemoteTranscriptPage.fromJson(page.toJson()).absence,
        RemoteTranscriptAbsence.noTranscriptFile,
      );
    });

    test('a store that yields no transcript path at all is the other reason',
        () async {
      // Nothing to derive a readable file from, for this session or any other
      // of the same agent — which is what `noChatView` has always meant, and
      // now means only.
      seedWorkspace();
      seedPaneSession('s-blind', agentId: 'antigravity');
      locator.paths['antigravity/ext-s-blind'] = ph.join(
        r'C:\store',
        'ext-s-blind.db',
      );

      final bindings = container.read(remoteHostBindingsProvider);
      final page = (await bindings.transcriptFor('s-blind')).page;

      expect(page.messages, isEmpty);
      expect(page.absence, RemoteTranscriptAbsence.noChatView);
      expect(
        RemoteTranscriptPage.fromJson(page.toJson()).absence,
        RemoteTranscriptAbsence.noChatView,
      );
    });

    test('the same agent, where its store does keep one, sends the turns',
        () async {
      // The refusal above is about this session, not about Antigravity: the
      // WSL install keeps a plain JSONL transcript for every conversation, and
      // sending `noChatView` for one of those was the wrong half of a
      // per-format answer.
      final store = Directory.systemTemp.createTempSync('karmashala_agy_rb_');
      addTearDown(() => removeTempDirectory(store));
      final transcript = File(
        ph.join(
          store.path,
          'brain',
          'ext-s-live',
          '.system_generated',
          'logs',
          'transcript.jsonl',
        ),
      )..parent.createSync(recursive: true);
      transcript.writeAsStringSync(
        jsonEncode({
          'step_index': 0,
          'source': 'USER_EXPLICIT',
          'type': 'USER_INPUT',
          'status': 'DONE',
          'created_at': '2026-09-09T10:00:00Z',
          'content': 'list the folder',
        }),
      );
      locator.paths['antigravity/ext-s-live'] = ph.join(
        store.path,
        'conversations',
        'ext-s-live.db',
      );

      seedWorkspace();
      seedPaneSession('s-live', agentId: 'antigravity');

      final bindings = container.read(remoteHostBindingsProvider);
      final page = (await bindings.transcriptFor('s-live')).page;

      expect(page.absence, isNull);
      expect(page.messages.single.text, 'list the folder');
    });

    // One read, two answers: the page the phone renders and what that same
    // parse says is in flight. Asking twice would double what the poll sweep
    // spends on a transcript, and the largest one here is 53 MB.
    group('the same read says what is running', () {
      /// Puts the registry's answer under the test's control — its production
      /// path reads hooks, a state file and a terminal grid.
      void statusIs(AgentActivityStatus status) {
        container.dispose();
        container = ProviderContainer(
          overrides: [
            ...fakeTerminalOverrides(database: db),
            sessionTranscriptLocatorProvider.overrideWithValue(locator),
            repositoryDiscoveryServiceProvider.overrideWithValue(discovery),
            autoImportRunnerProvider.overrideWithValue(
              (_) async => const ImportSummary(),
            ),
            remoteDeliveryStageProvider.overrideWithValue(
              (sessionId) async => 'working',
            ),
            remoteApprovalEvidenceProvider.overrideWithValue(
              (sessionId) async => null,
            ),
            remoteSessionPresenceProvider.overrideWithValue(
              (sessionId) => (note: null, lastSeen: null),
            ),
            sessionStatusLookupProvider.overrideWithValue(
              (sessionId) => AgentStatusReport(
                agentId: 'antigravity',
                sessionId: sessionId,
                status: status,
                observedAt: now,
                source: AgentStatusSource.hook,
              ),
            ),
          ],
        );
      }

      // §19: a session that is working and whose record we cannot read must
      // not answer with an empty list, which reads as "nothing is running".
      test('a working session we cannot look into says which nothing', () async {
        statusIs(AgentActivityStatus.working);
        seedWorkspace();
        seedPaneSession('s-anti', agentId: 'antigravity');
        locator.paths['antigravity/ext-s-anti'] =
            ph.join(r'C:\store', 'conversations', 'ext-s-anti.db');

        final record = await container
            .read(remoteHostBindingsProvider)
            .transcriptFor('s-anti');

        expect(record.page.absence, RemoteTranscriptAbsence.noTranscriptFile);
        expect(record.activity.calls, isEmpty);
        expect(record.activity.absence, RemoteActivityAbsence.noRecord);
        // The fact survives the round trip a phone actually reads it through.
        expect(
          RemoteSessionActivity.fromJson(
            record.activity.toJson(),
          ).absence,
          RemoteActivityAbsence.noRecord,
        );
      });

      test('...and an idle one answers plainly that nothing is', () async {
        statusIs(AgentActivityStatus.idle);
        seedWorkspace();
        seedPaneSession('s-anti', agentId: 'antigravity');

        final record = await container
            .read(remoteHostBindingsProvider)
            .transcriptFor('s-anti');

        expect(record.activity.calls, isEmpty);
        expect(
          record.activity.absence,
          isNull,
          reason: 'nothing is running, and the status badge says so',
        );
      });
    });

    test('a nothing the host cannot account for stays unexplained', () async {
      seedWorkspace();
      // The event-log path: an ordinary session with no turns yet. Claiming a
      // structural reason here would be the same invention in reverse.
      seedSession('s-quiet');

      final bindings = container.read(remoteHostBindingsProvider);
      final page = (await bindings.transcriptFor('s-quiet')).page;

      expect(page.messages, isEmpty);
      expect(page.absence, isNull);
      expect(page.toJson().containsKey('absence'), isFalse);
    });
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
    final page = (await bindings.transcriptFor('s1')).page;

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
    final page = (await bindings.transcriptFor('child')).page;

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

  // --- Keys are offered for an open prompt, and for nothing else ------------
  //
  // `awaitingApproval` answers "is this session holding the user up" — the
  // question the badge, the tray and the phone's attention row all ask. It
  // does NOT answer "is a prompt open": Claude Code fires the same
  // notification for a permission request and for the 60-second nudge after a
  // turn ends, and a *worker's* prompt stops the session at a screen this
  // session's Enter never reaches. The desktop card learned to tell them
  // apart; the phone was still shown Approve and Deny for all three, and
  // approve types Enter — which at an idle prompt submits whatever is in the
  // composer.
  group('the phone is offered keys only for a prompt a source could see', () {
    ProviderContainer withReport(AgentStatusReport? report) {
      final built = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          remoteDeliveryStageProvider.overrideWithValue(
            (sessionId) async => 'working',
          ),
          remoteApprovalEvidenceProvider.overrideWithValue(
            (sessionId) async => report,
          ),
          remoteSessionPresenceProvider.overrideWithValue(
            (sessionId) => (note: null, lastSeen: null),
          ),
        ],
      );
      addTearDown(built.dispose);
      return built;
    }

    /// A session on an agent that HAS named its keys, so a missing label can
    /// only mean this code withheld it.
    void seedClaudeSession(String id) {
      AgentInstallationDao(db).insert(
        AgentInstallation(
          id: 'i2',
          agentId: 'claudeCode',
          executable: path(r'C:\bin\claude.exe'),
          createdAt: now,
        ),
      );
      SessionDao(db).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'i2',
          title: 'Fix the build',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: now,
          surface: SessionSurface.external,
        ),
      );
    }

    AgentStatusReport stopped(AgentWaitKind waiting) => AgentStatusReport(
      agentId: 'claudeCode',
      sessionId: 'ext1',
      status: AgentActivityStatus.awaitingApproval,
      observedAt: now,
      source: AgentStatusSource.hook,
      evidence: const ['Claude needs your permission to use Bash'],
      waiting: waiting,
    );

    test('an open prompt is sent with both of the keys the agent named',
        () async {
      seedWorkspace();
      seedClaudeSession('c1');
      final bindings = withReport(
        stopped(AgentWaitKind.approval),
      ).read(remoteHostBindingsProvider);

      final request = await bindings.approvalEvidenceFor('c1');

      expect(request.waiting, RemoteWaitKind.approval);
      expect(request.approveLabel, 'Approve');
      expect(request.denyLabel, 'Deny');
      expect(request.evidence, [
        'Claude needs your permission to use Bash',
      ]);
    });

    test('a session at its own prompt is sent its words and no keys', () async {
      seedWorkspace();
      seedClaudeSession('c1');
      final bindings = withReport(
        stopped(AgentWaitKind.input),
      ).read(remoteHostBindingsProvider);

      final request = await bindings.approvalEvidenceFor('c1');

      expect(request.waiting, RemoteWaitKind.input);
      expect(request.approveLabel, isNull);
      expect(request.denyLabel, isNull);
      // The evidence still travels: the phone shows what the agent said, it
      // just has nothing to press.
      expect(request.evidence, [
        'Claude needs your permission to use Bash',
      ]);
    });

    test('a wait no source could name is sent no keys either', () async {
      // `worker_permission_prompt` is the real one: a prompt drawn somewhere
      // this session's Enter does not land.
      seedWorkspace();
      seedClaudeSession('c1');
      final bindings = withReport(
        stopped(AgentWaitKind.unrecorded),
      ).read(remoteHostBindingsProvider);

      final request = await bindings.approvalEvidenceFor('c1');

      expect(request.waiting, RemoteWaitKind.unrecorded);
      expect(request.approveLabel, isNull);
      expect(request.denyLabel, isNull);
    });

    test('a session that is not stopped at all carries nothing', () async {
      seedWorkspace();
      seedClaudeSession('c1');
      final bindings = withReport(
        AgentStatusReport(
          agentId: 'claudeCode',
          sessionId: 'ext1',
          status: AgentActivityStatus.working,
          observedAt: now,
          source: AgentStatusSource.hook,
          evidence: const ['still going'],
          // A stale wait kind from an earlier report must not resurrect keys
          // for a session that is working.
          waiting: AgentWaitKind.approval,
        ),
      ).read(remoteHostBindingsProvider);

      final request = await bindings.approvalEvidenceFor('c1');

      expect(request.waiting, RemoteWaitKind.unrecorded);
      expect(request.evidence, isEmpty);
      expect(request.approveLabel, isNull);
      expect(request.denyLabel, isNull);
    });

    test('and the key is refused at the press, not only withheld from the '
        'card', () async {
      // The other half of the same rule: a phone holding a stale card, or an
      // older build that was handed labels it should not have been, must not
      // be able to type Enter into a session that merely finished its turn.
      seedWorkspace();
      seedClaudeSession('c1');
      final bindings = withReport(
        stopped(AgentWaitKind.input),
      ).read(remoteHostBindingsProvider);

      await expectLater(
        bindings.answerApproval('c1', 'approve'),
        throwsA(
          isA<RemoteApiRefusal>()
              .having((r) => r.code, 'code', ErrorCode.badRequest)
              .having(
                (r) => r.message,
                'message',
                contains('no prompt open'),
              ),
        ),
      );
    });

    test('an open prompt gets past that guard and stops on the terminal',
        () async {
      seedWorkspace();
      seedClaudeSession('c1');
      final bindings = withReport(
        stopped(AgentWaitKind.approval),
      ).read(remoteHostBindingsProvider);

      // No live pane in this container, so the press itself has nowhere to
      // land — which is the refusal that proves the wait-kind guard passed.
      await expectLater(
        bindings.answerApproval('c1', 'approve'),
        throwsA(
          isA<RemoteApiRefusal>().having(
            (r) => r.message,
            'message',
            contains('no live terminal'),
          ),
        ),
      );
    });
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
      final page = (await bindings.transcriptFor('imp1')).page;
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

    await bindings.registerPush(
      fakeDevice().id,
      'tok3n',
      'android',
      const CompanionPresence(
        deviceKind: CompanionDeviceKind.phone,
        visibility: CompanionVisibility.background,
        focusedSessionId: 's1',
      ),
    );

    final row = dao.getById(fakeDevice().id)!;
    expect(row.pushToken, 'tok3n');
    expect(row.pushPlatform, 'android');
    expect(row.presence.deviceKind, CompanionDeviceKind.phone);
    expect(row.presence.visibility, CompanionVisibility.background);
    expect(row.presence.focusedSessionId, 's1');
    // Every reading carries its age (§19); a presence with no time is not one.
    expect(row.presence.at, isNotNull);
  });

  // A question is answered with the option the user picked, never with
  // Approve — which is Enter, which answers with whatever is highlighted.
  group('an agent question is carried whole and answered only as asked', () {
    const asked = AgentQuestionSet(
      toolUseId: 'toolu_1',
      questions: [
        AgentQuestion(
          question: 'Pick a fruit',
          options: [
            AgentQuestionOption(label: 'Apple'),
            AgentQuestionOption(label: 'Banana'),
          ],
        ),
      ],
    );

    ProviderContainer with_(
      AgentStatusReport? report, {
      AgentQuestionSet? open = asked,
    }) {
      final built = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          remoteDeliveryStageProvider.overrideWithValue(
            (sessionId) async => 'working',
          ),
          remoteApprovalEvidenceProvider.overrideWithValue(
            (sessionId) async => report,
          ),
          remoteOpenQuestionProvider.overrideWithValue(
            (sessionId, agentId) async => open,
          ),
          remoteSessionPresenceProvider.overrideWithValue(
            (sessionId) => (note: null, lastSeen: null),
          ),
        ],
      );
      addTearDown(built.dispose);
      return built;
    }

    void seedClaude(String id) {
      AgentInstallationDao(db).insert(
        AgentInstallation(
          id: 'i2',
          agentId: 'claudeCode',
          executable: path(r'C:\bin\claude.exe'),
          createdAt: now,
        ),
      );
      SessionDao(db).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'i2',
          title: 'Ask me',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: now,
          surface: SessionSurface.external,
        ),
      );
    }

    AgentStatusReport showing(AgentWaitKind waiting) => AgentStatusReport(
      agentId: 'claudeCode',
      sessionId: 'ext1',
      status: AgentActivityStatus.awaitingApproval,
      observedAt: now,
      source: AgentStatusSource.terminalGrid,
      evidence: const ['Pick a fruit'],
      waiting: waiting,
    );

    RemoteQuestionAnswerRequest answering({
      String toolUseId = 'toolu_1',
      List<RemoteQuestionAnswer> answers = const [
        RemoteQuestionAnswer.options([1]),
      ],
    }) => RemoteQuestionAnswerRequest(
      sessionId: 'q1',
      toolUseId: toolUseId,
      answers: answers,
    );

    Matcher refusedWith(String words) => throwsA(
      isA<RemoteApiRefusal>().having((r) => r.message, 'message', contains(words)),
    );

    test('the question travels with the request, and no keys beside it',
        () async {
      seedWorkspace();
      seedClaude('q1');
      final bindings = with_(
        showing(AgentWaitKind.question),
      ).read(remoteHostBindingsProvider);

      final request = await bindings.approvalEvidenceFor('q1');

      expect(request.waiting, RemoteWaitKind.question);
      expect(request.question!.toolUseId, 'toolu_1');
      expect(request.question!.questions.single.options.last.label, 'Banana');
      expect(request.approveLabel, isNull);
      expect(request.denyLabel, isNull);
    });

    test('a message is refused while the question is open', () async {
      seedWorkspace();
      seedClaude('q1');
      final bindings = with_(
        showing(AgentWaitKind.question),
      ).read(remoteHostBindingsProvider);
      await expectLater(
        bindings.sendPrompt('q1', 'carry on'),
        refusedWith('answer it first'),
      );
    });

    test('Approve is refused for a question', () async {
      seedWorkspace();
      seedClaude('q1');
      final bindings = with_(
        showing(AgentWaitKind.question),
      ).read(remoteHostBindingsProvider);
      await expectLater(
        bindings.answerApproval('q1', 'approve'),
        refusedWith('no prompt open'),
      );
    });

    test('an answer with no question on screen is refused', () async {
      seedWorkspace();
      seedClaude('q1');
      final bindings = with_(
        showing(AgentWaitKind.input),
      ).read(remoteHostBindingsProvider);
      await expectLater(
        bindings.answerQuestion(answering()),
        refusedWith('no question open'),
      );
    });

    test('an answer to a question that has since changed is refused',
        () async {
      seedWorkspace();
      seedClaude('q1');
      final bindings = with_(
        showing(AgentWaitKind.question),
      ).read(remoteHostBindingsProvider);
      await expectLater(
        bindings.answerQuestion(answering(toolUseId: 'toolu_older')),
        refusedWith('already been answered'),
      );
    });

    test('an answer that does not fit the question is refused', () async {
      seedWorkspace();
      seedClaude('q1');
      final bindings = with_(
        showing(AgentWaitKind.question),
      ).read(remoteHostBindingsProvider);
      await expectLater(
        bindings.answerQuestion(
          answering(answers: const [RemoteQuestionAnswer.options([5])]),
        ),
        refusedWith('no such option'),
      );
    });

    test('a fitting answer passes every guard and stops on the terminal',
        () async {
      seedWorkspace();
      seedClaude('q1');
      final bindings = with_(
        showing(AgentWaitKind.question),
      ).read(remoteHostBindingsProvider);
      // No live pane here: the refusal that proves the keys were built.
      await expectLater(
        bindings.answerQuestion(answering()),
        refusedWith('no live terminal'),
      );
    });
  });

  // A menu on the agent's screen — folder trust here — is answered by option.
  // Approve would be Enter, and Enter on this one is "No, exit".
  group('a menu on the screen is carried whole and answered by option', () {
    late List<String> pressed;
    late int highlighted;
    const options = ['No, exit', 'Yes, I trust this folder'];

    List<String> screen() => [
      ' Security guide',
      '',
      for (var i = 0; i < options.length; i++)
        i == highlighted ? ' ❯ ${options[i]}' : '   ${options[i]}',
      '',
      ' Enter to confirm · Esc to cancel',
    ];

    ProviderContainer with_(AgentStatusReport? report) {
      pressed = [];
      highlighted = 0;
      final built = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          remoteDeliveryStageProvider.overrideWithValue(
            (sessionId) async => 'working',
          ),
          remoteApprovalEvidenceProvider.overrideWithValue(
            (sessionId) async => report,
          ),
          remoteSessionPresenceProvider.overrideWithValue(
            (sessionId) => (note: null, lastSeen: null),
          ),
          sessionMenuAnswererProvider.overrideWithValue(
            SessionMenuAnswerer(
              readScreen: (_) => screen(),
              supportFor: (_) => const AgentMenuSupport(markers: ['❯']),
              isAsking: (_) => report?.hasOpenPrompt ?? false,
              press: (_, keys) {
                pressed.add(keys);
                if (keys == '\x1b[B') highlighted++;
                return true;
              },
              poll: const Duration(milliseconds: 1),
            ),
          ),
        ],
      );
      addTearDown(built.dispose);
      return built;
    }

    void seedClaude(String id) {
      AgentInstallationDao(db).insert(
        AgentInstallation(
          id: 'i2',
          agentId: 'claudeCode',
          executable: path(r'C:\bin\claude.exe'),
          createdAt: now,
        ),
      );
      SessionDao(db).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'i2',
          title: 'Trust me',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: now,
          surface: SessionSurface.external,
        ),
      );
    }

    AgentStatusReport showing(AgentWaitKind waiting) => AgentStatusReport(
      agentId: 'claudeCode',
      sessionId: 'ext1',
      status: AgentActivityStatus.awaitingApproval,
      observedAt: now,
      source: AgentStatusSource.terminalGrid,
      evidence: const ['Security guide'],
      waiting: waiting,
    );

    test('the menu travels with the request, and no Approve beside it',
        () async {
      seedWorkspace();
      seedClaude('m1');
      final bindings = with_(
        showing(AgentWaitKind.approval),
      ).read(remoteHostBindingsProvider);

      final request = await bindings.approvalEvidenceFor('m1');

      expect(request.menu!.options, options);
      expect(request.menu!.highlighted, 0);
      expect(request.approveLabel, isNull);
      expect(request.denyLabel, isNull);
    });

    test('the option chosen is the option confirmed', () async {
      seedWorkspace();
      seedClaude('m1');
      final bindings = with_(
        showing(AgentWaitKind.approval),
      ).read(remoteHostBindingsProvider);
      final menu = (await bindings.approvalEvidenceFor('m1')).menu!;

      final chosen = await bindings.answerMenu(
        RemoteMenuAnswerRequest(sessionId: 'm1', menuId: menu.menuId, option: 1),
      );

      expect(chosen, 'Yes, I trust this folder');
      expect(pressed, ['\x1b[B', '\r']);
    });

    // Found on the Oppo: the empty session offered "Explain architecture"
    // beside the trust menu. Sent, its Enter would have chosen "No, exit".
    test('a message is refused while the menu is open, and nothing typed',
        () async {
      seedWorkspace();
      seedClaude('m1');
      final bindings = with_(
        showing(AgentWaitKind.approval),
      ).read(remoteHostBindingsProvider);
      await expectLater(
        bindings.sendPrompt('m1', 'Explain the architecture'),
        throwsA(
          isA<RemoteApiRefusal>().having(
            (r) => r.message,
            'message',
            contains('answer it first'),
          ),
        ),
      );
      expect(pressed, isEmpty);
    });

    test('an answer with no prompt open is refused, and nothing pressed',
        () async {
      seedWorkspace();
      seedClaude('m1');
      final bindings = with_(
        showing(AgentWaitKind.input),
      ).read(remoteHostBindingsProvider);
      await expectLater(
        bindings.answerMenu(
          const RemoteMenuAnswerRequest(sessionId: 'm1', menuId: 'x', option: 1),
        ),
        throwsA(isA<RemoteApiRefusal>()),
      );
      expect(pressed, isEmpty);
    });

    test('an answer for a menu that has since changed chooses nothing',
        () async {
      seedWorkspace();
      seedClaude('m1');
      final bindings = with_(
        showing(AgentWaitKind.approval),
      ).read(remoteHostBindingsProvider);
      await expectLater(
        bindings.answerMenu(
          const RemoteMenuAnswerRequest(
            sessionId: 'm1',
            menuId: 'not-this-one',
            option: 1,
          ),
        ),
        throwsA(
          isA<RemoteApiRefusal>().having(
            (r) => r.message,
            'message',
            contains('prompt changed'),
          ),
        ),
      );
      expect(pressed, isEmpty);
    });
  });

  // The registry resolves a transcript only for a session it has to probe, and
  // a session whose status is fresh from a hook or the screen is never one. The
  // question is still in the transcript: found through the locator instead.
  test('an open question is read from the transcript even when the status '
      'registry never resolved it', () async {
    seedWorkspace();
    AgentInstallationDao(db).insert(
      AgentInstallation(
        id: 'i2',
        agentId: 'claudeCode',
        executable: path(r'C:\bin\claude.exe'),
        createdAt: now,
      ),
    );
    SessionDao(db).insert(
      Session(
        id: 'q9',
        repositoryId: 'r1',
        agentInstallationId: 'i2',
        title: 'Ask me',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: now,
        surface: SessionSurface.pane,
        externalSessionId: 'ext-q9',
      ),
    );
    final dir = Directory.systemTemp.createTempSync('karmashala_question_');
    addTearDown(() => removeTempDirectory(dir));
    final transcript = File(ph.join(dir.path, 'ext-q9.jsonl'))
      ..writeAsStringSync(
        '${jsonEncode({
          'type': 'assistant',
          'message': {
            'content': [
              {
                'type': 'tool_use',
                'id': 'toolu_9',
                'name': 'AskUserQuestion',
                'input': {
                  'questions': [
                    {
                      'question': 'Pick a fruit',
                      'options': [
                        {'label': 'Apple'},
                        {'label': 'Banana'},
                      ],
                    },
                  ],
                },
              },
            ],
          },
        })}\n',
      );
    locator.paths['claudeCode/ext-q9'] = transcript.path;

    final open = await container.read(remoteOpenQuestionProvider)(
      'q9',
      'claudeCode',
    );

    expect(open?.toolUseId, 'toolu_9');
    expect(open?.questions.single.options.last.label, 'Banana');
  });
}