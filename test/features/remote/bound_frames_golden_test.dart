/// The bound frame set, frozen byte for byte.
///
/// `remoteHostBindingsProvider` is the one object every companion frame is
/// answered from, and its whole contract is the payload that comes back: a
/// phone receives these fields, with these words in them, for these requests.
/// Splitting the bindings into per-family files is meant to change none of it,
/// and every ordinary test in this folder checks one binding at a time — so
/// nothing would have noticed a family arriving with a field dropped, a
/// refusal reworded, or a snapshot built in a different order.
///
/// So the whole answer is committed. Each companion [FrameType] is driven
/// through [HostSessionApi] — in the enum's own declaration order, which is
/// the order the api's switch registers them in — against the **production**
/// bindings over a seeded in-memory database, and every frame that comes back
/// is recorded. A refactor that does not touch behaviour leaves this file
/// alone; a change that does touch it has to be made deliberately, and the
/// diff says exactly what a phone will see differently.
///
/// The five probe-shaped lookups are stubbed with the same values the counted
/// tests beside this one fake, because their production paths are a git/gh
/// probe, the agent status sources and the filesystem — see
/// `remote_bindings_test.dart` and `remote_workspace_test.dart`.
///
/// Regenerate only when the change is intended, and never as a side effect of
/// `--update-goldens` (which is why this is its own variable):
///
/// ```
/// KARMASHALA_WRITE_BOUND_FRAMES_GOLDEN=1 flutter test \
///   test/features/remote/bound_frames_golden_test.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_installation.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:karmashala/src/features/cli_detection/domain/imported_session.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/projects/domain/project.dart';
import 'package:karmashala/src/features/remote/application/host_session_api.dart';
import 'package:karmashala/src/features/remote/application/remote_bindings.dart';
import 'package:karmashala/src/features/remote/application/remote_providers.dart';
import 'package:karmashala/src/features/remote/data/companion_attachment_store.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:karmashala/src/features/repositories/application/repository_discovery_provider.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/repositories/domain/repository.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_event_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session.dart';
import 'package:karmashala/src/features/sessions/domain/session_event.dart';
import 'package:karmashala/src/features/sessions/domain/session_event_types.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';

import '../../support/fakes.dart';
import '../terminal/fake_instance.dart';
import 'fake_bindings.dart' show fakeDevice;

const _goldenPath = 'test/features/remote/bound_frames.golden.json';

/// The store scan answered from a map, so nothing walks the owner's own
/// `~/.claude`. Same seam as `remote_bindings_test.dart`'s.
class _NoStore implements SessionTranscriptLocator {
  @override
  Future<String?> locate({
    required String agentId,
    required String externalSessionId,
  }) async => null;

  @override
  Future<Map<String, String>> index() async => const {};
}

typedef _Frame = ({FrameType type, String? id, Map<String, Object?> payload});

void main() {
  test('the bound frame set matches the committed golden', () async {
    final now = DateTime.utc(2026, 8, 31, 10);
    final db = AppDatabase.memory();
    addTearDown(db.close);

    EnvironmentPath at(String path) =>
        EnvironmentPath(environmentId: 'windows', path: path);

    ExecutionEnvironmentDao(db).upsert(
      ExecutionEnvironment(
        id: 'windows',
        kind: EnvironmentKind.windowsNative,
        name: 'Windows',
        createdAt: now,
      ),
    );
    // Three environments, because the badge and the attachment answer are
    // decided by the kind: the local host badges nothing and can be written
    // to, WSL badges and can be written to, and SSH badges and cannot.
    ExecutionEnvironmentDao(db).upsert(
      ExecutionEnvironment(
        id: 'wsl:Ubuntu',
        kind: EnvironmentKind.wsl,
        name: 'Ubuntu',
        wslDistribution: 'Ubuntu',
        createdAt: now,
      ),
    );
    ExecutionEnvironmentDao(db).upsert(
      ExecutionEnvironment(
        id: 'ssh:build-box',
        kind: EnvironmentKind.ssh,
        name: 'build-box',
        sshHostId: 'h1',
        createdAt: now,
      ),
    );
    ProjectDao(db).insert(
      Project(id: 'p1', name: 'Proj', root: at(r'C:\work'), createdAt: now),
    );
    ProjectDao(db).insert(
      Project(
        id: 'p2',
        name: 'Api',
        root: const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/home/dev/work',
        ),
        createdAt: now,
      ),
    );
    ProjectDao(db).insert(
      Project(
        id: 'p3',
        name: 'Farm',
        root: const EnvironmentPath(
          environmentId: 'ssh:build-box',
          path: '/srv/farm',
        ),
        createdAt: now,
      ),
    );
    RepositoryDao(db).insert(
      Repository(
        id: 'r1',
        projectId: 'p1',
        name: 'proj-repo',
        path: at(r'C:\work\proj'),
        createdAt: now,
      ),
    );
    RepositoryDao(db).insert(
      Repository(
        id: 'r2',
        projectId: 'p2',
        name: 'api',
        path: const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/home/dev/work/api',
        ),
        createdAt: now,
      ),
    );
    RepositoryDao(db).insert(
      Repository(
        id: 'r3',
        projectId: 'p3',
        name: 'farm',
        path: const EnvironmentPath(
          environmentId: 'ssh:build-box',
          path: '/srv/farm/runner',
        ),
        createdAt: now,
      ),
    );
    // One known agent and one the registry has never heard of: `agentOption`
    // has a branch for each, and only a session on the unknown one produces
    // the structural absence word.
    AgentInstallationDao(db).insert(
      AgentInstallation(
        id: 'i1',
        agentId: 'claudeCode',
        executable: at(r'C:\bin\claude.exe'),
        createdAt: now,
      ),
    );
    AgentInstallationDao(db).insert(
      AgentInstallation(
        id: 'i2',
        agentId: 'mystery',
        executable: at(r'C:\bin\mystery.exe'),
        createdAt: now,
      ),
    );
    AgentInstallationDao(db).insert(
      AgentInstallation(
        id: 'i3',
        agentId: 'claudeCode',
        executable: const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/usr/local/bin/claude',
        ),
        createdAt: now,
      ),
    );
    AgentInstallationDao(db).insert(
      AgentInstallation(
        id: 'i4',
        agentId: 'claudeCode',
        executable: const EnvironmentPath(
          environmentId: 'ssh:build-box',
          path: '/usr/local/bin/claude',
        ),
        createdAt: now,
      ),
    );

    void seedSession(
      String id, {
      required String installationId,
      required String title,
      String repositoryId = 'r1',
      SessionSurface surface = SessionSurface.external,
      String? parentSessionId,
    }) => SessionDao(db).insert(
      Session(
        id: id,
        repositoryId: repositoryId,
        agentInstallationId: installationId,
        title: title,
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: now,
        surface: surface,
        parentSessionId: parentSessionId,
      ),
    );

    seedSession('s1', installationId: 'i1', title: 'Fix the build');
    seedSession(
      's2',
      installationId: 'i1',
      title: 'Follow-up',
      parentSessionId: 's1',
    );
    // Pane surface on an agent whose store nothing here opens: the one shape
    // that produces `RemoteTranscriptAbsence.noChatView`.
    seedSession(
      's3',
      installationId: 'i2',
      title: 'Unreadable store',
      surface: SessionSurface.pane,
    );
    // The two badged environments, and the two attachment answers they give:
    // a WSL agent reads a path this desktop can write, an SSH one cannot.
    seedSession(
      's4',
      installationId: 'i3',
      title: 'In the subsystem',
      repositoryId: 'r2',
    );
    seedSession(
      's5',
      installationId: 'i4',
      title: 'On another machine',
      repositoryId: 'r3',
    );
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
        updatedAt: DateTime.utc(2026, 8, 31, 8),
      ),
    );
    ImportedSessionDao(db).insertIfAbsent(
      ImportedSession(
        id: 'imp2',
        repositoryId: 'r2',
        cli: 'claudeCode',
        externalId: 'x2',
        environmentId: 'wsl:Ubuntu',
        filePath: '/home/dev/.claude/imp2.jsonl',
        storeHome: '/home/dev/.claude',
        isSubagent: false,
        preview: 'a subsystem conversation',
        title: 'Old subsystem chat',
        createdAt: now,
        updatedAt: DateTime.utc(2026, 8, 31, 7),
      ),
    );

    void append(String sessionId, String type, Map<String, Object?> data) =>
        SessionEventDao(db).append(
          SessionEvent(
            sessionId: sessionId,
            seq: 0,
            type: type,
            payload: jsonEncode(data),
            createdAt: now,
          ),
        );
    append('s1', SessionEventTypes.userMessage, {'text': 'build it'});
    append('s1', SessionEventTypes.agentMessage, {'text': 'building'});
    append('s1', SessionEventTypes.error, {'text': 'it did not compile'});
    append('s1', SessionEventTypes.sessionFailed, const {});
    append('s1', SessionEventTypes.sessionCancelled, const {});
    append('s2', SessionEventTypes.userMessage, {'text': 'and again'});

    final attachmentRoot = await Directory.systemTemp.createTemp(
      'karmashala-bound-frames-',
    );
    addTearDown(() => attachmentRoot.delete(recursive: true));
    final projectFolder = await Directory.systemTemp.createTemp(
      'karmashala-bound-project-',
    );
    addTearDown(() => projectFolder.delete(recursive: true));

    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(now)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('new-')),
        sessionTranscriptLocatorProvider.overrideWithValue(_NoStore()),
        repositoryDiscoveryServiceProvider.overrideWithValue(
          FakeRepositoryDiscoveryService(),
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
        companionAttachmentStoreProvider.overrideWith(
          (ref) async => CompanionAttachmentStore(attachmentRoot),
        ),
        // The probe-shaped lookups, faked exactly as the counted tests beside
        // this one fake them: a git/gh probe, the agent status sources, the
        // filesystem and the cached checkout stat.
        remoteDeliveryStageProvider.overrideWithValue((_) async => 'working'),
        remoteApprovalEvidenceProvider.overrideWithValue((_) async => null),
        remoteSessionPresenceProvider.overrideWithValue(
          (_) => (note: 'running here', lastSeen: DateTime.utc(2026, 8, 31, 9)),
        ),
        remoteFolderMissingProvider.overrideWithValue((_) => false),
        remoteCheckoutBranchProvider.overrideWithValue((_) => 'main'),
      ],
    );
    addTearDown(container.dispose);

    final launcher = container.read(sessionLauncherProvider);
    final claudeMode = launcher.permissionFor(
      'claudeCode',
      SessionPurpose.newSession,
    );
    // A session with a live pane, because `prompt.send` types into one and an
    // attachment is offered into its composer.
    final live = (await launcher.launch(
      SessionLaunchRequest(
        repository: RepositoryDao(db).getById('r1')!,
        installation: AgentInstallationDao(db).getById('i1')!,
        title: 'Live pane',
        purpose: SessionPurpose.newSession,
        permissionOverride: claudeMode,
      ),
    )).session.id;

    final sent = <_Frame>[];
    final api = HostSessionApi(
      device: fakeDevice(),
      bindings: container.read(remoteHostBindingsProvider),
      send: (type, {id, payload = const {}}) async {
        sent.add((type: type, id: id, payload: payload));
        return true;
      },
    );

    var seq = 0;
    Future<List<_Frame>> ask(
      FrameType type,
      Map<String, Object?> payload,
    ) async {
      final from = sent.length;
      await api.handleEnvelope(
        Envelope.of(
          type,
          seq: seq++,
          id: 'q$seq',
          payload: payload,
          version: kProtocolVersion,
        ),
      );
      return sent.sublist(from);
    }

    /// One companion frame with the request the tests already fake for it.
    final cases = <FrameType, List<Map<String, Object?>>>{
      FrameType.sessionsList: [const {}],
      FrameType.sessionSubscribe: [
        {'sessionId': 's1'},
      ],
      FrameType.sessionUnsubscribe: [
        {'sessionId': 's1'},
      ],
      FrameType.transcriptGet: [
        {'sessionId': 's1'},
        {'sessionId': 's2'},
        {'sessionId': 's3'},
        {'sessionId': 'imp1'},
      ],
      FrameType.promptSend: [
        {'sessionId': live, 'text': 'carry on'},
        {'sessionId': 'imp1', 'text': 'carry on'},
      ],
      FrameType.approvalAnswer: [
        {'sessionId': 's1', 'decision': 'approve'},
      ],
      FrameType.notificationsRegister: [
        {'token': 't0k', 'platform': 'android'},
      ],
      FrameType.workspaceList: [const {}],
      FrameType.projectsList: [const {}],
      FrameType.projectAdd: [
        {'requestId': 'add-1', 'name': 'Workspace', 'path': projectFolder.path},
      ],
      FrameType.sessionStart: [
        {
          'requestId': 'start-1',
          'repositoryId': 'r1',
          'installationId': 'i1',
          'permissionMode': claudeMode.canonical,
          'title': 'From the phone',
          'message': 'hello',
        },
        {
          'requestId': 'start-2',
          'repositoryId': 'r1',
          'installationId': 'i2',
          'permissionMode': claudeMode.canonical,
        },
      ],
      FrameType.sessionResume: [
        {'requestId': 'resume-1', 'sessionId': live},
        {'requestId': 'resume-2', 'sessionId': 's1'},
      ],
      FrameType.sessionActivity: [
        {'sessionId': 's1'},
      ],
      FrameType.attachmentBegin: [
        {'sessionId': live, 'name': 'shot.png', 'type': 'image/png', 'bytes': 4},
      ],
      FrameType.attachmentChunk: [
        // Filled in below with the id the store just handed out.
      ],
    };

    final recorded = <Map<String, Object?>>[];
    String? uploadId;
    for (final type in FrameType.values) {
      // A frame the companion sends is a frame gated on a capability, and the
      // host's own carry none. Neither `origin` nor `sentBy` says it on its
      // own: `session.activity` travels both ways and is a request, `error`
      // travels both ways and is not.
      if (type.capability == null) continue;
      // Unguarded on purpose — a frame added to the protocol has to be given a
      // request here rather than quietly missing from the contract.
      final requests = cases[type]!;
      if (type == FrameType.attachmentChunk) {
        requests.add({
          'uploadId': uploadId,
          'seq': 0,
          'data': base64Encode(const [1, 2, 3, 4]),
        });
      }
      final answers = <Map<String, Object?>>[];
      for (final request in requests) {
        final out = await ask(type, request);
        if (type == FrameType.attachmentBegin) {
          uploadId = out.first.payload['uploadId'] as String?;
        }
        answers.add({
          'request': request,
          'frames': [
            for (final frame in out)
              {'type': frame.type.wire, 'payload': frame.payload},
          ],
        });
      }
      recorded.add({
        'frame': type.wire,
        'capability': type.capability?.wire,
        'cases': answers,
      });
    }

    // The one flow that crosses two frames: a prompt naming the upload just
    // made is *offered* into the desktop composer, never sent.
    final offered = await ask(FrameType.promptSend, {
      'sessionId': live,
      'text': 'look at this',
      'attachment': uploadId,
    });

    await api.sendHostStatus();
    final status = sent.last;

    final catalogue = <String, Object?>{
      'note':
          'Every companion frame answered from the production bindings, in '
          'FrameType declaration order. Regenerate with '
          'KARMASHALA_WRITE_BOUND_FRAMES_GOLDEN=1; see '
          'test/features/remote/bound_frames_golden_test.dart.',
      'frames': recorded,
      'attachmentOffer': {
        'frames': [
          for (final frame in offered)
            {'type': frame.type.wire, 'payload': frame.payload},
        ],
      },
      'hostStatus': status.payload,
    };

    // Everything the machine decides rather than the bindings: the desktop's
    // own name, the folder the temp directory happened to get, and the
    // upload id the store's secure RNG chose.
    var encoded = '${const JsonEncoder.withIndent('  ').convert(catalogue)}\n';
    for (final (from, to) in <(String, String)>[
      (projectFolder.resolveSymbolicLinksSync(), '<projectFolder>'),
      (projectFolder.path, '<projectFolder>'),
      (attachmentRoot.path, '<attachmentRoot>'),
      (Platform.localHostname, '<hostName>'),
      if (uploadId case final id?) (id, '<uploadId>'),
    ]) {
      encoded = encoded.replaceAll(jsonEncode(from).replaceAll('"', ''), to);
    }

    final file = File(_goldenPath);
    if (Platform.environment['KARMASHALA_WRITE_BOUND_FRAMES_GOLDEN'] == '1') {
      file.writeAsStringSync(encoded);
      // ignore: avoid_print
      print('wrote $_goldenPath');
    }

    expect(
      file.existsSync(),
      isTrue,
      reason: '$_goldenPath is missing; see the header of this file',
    );
    expect(
      encoded,
      file.readAsStringSync(),
      reason:
          'The bound frame set changed. If that was intended, regenerate the '
          'golden; if it was a refactor, something moved that should not have.',
    );
  });
}
