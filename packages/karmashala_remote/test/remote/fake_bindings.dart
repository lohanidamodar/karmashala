import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/host.dart';

/// In-memory bindings: sessions, transcripts and recorded actions, with no
/// providers, processes or terminals anywhere near them.
class FakeRemoteBindings {
  final Map<String, RemoteSessionSnapshot> sessions = {};
  final Map<String, List<RemoteTranscriptMessage>> transcripts = {};

  /// Why a session's transcript is empty, for a host that can say — the
  /// `agentSupportsChatView` refusal, as the production bindings report it.
  final Map<String, RemoteTranscriptAbsence> absences = {};

  /// What each session is doing, as the same read that served the transcript
  /// reports it. Unset answers "nothing is running, observed at [observedAt]".
  final Map<String, RemoteSessionActivity> activities = {};

  /// The host clock these readings are stamped with, so a test can say what a
  /// call's elapsed time is rather than race the wall.
  DateTime observedAt = DateTime.utc(2026, 9, 7, 12);
  final Map<String, String?> stages = {};
  final Map<String, RemoteApprovalRequest> approvals = {};
  final List<({String sessionId, String text})> prompts = [];

  /// The upload each prompt quoted, in step with [prompts]. Kept beside them
  /// rather than in them so the existing expectations still read as a list of
  /// what was said.
  final List<String?> promptAttachments = [];

  /// Every chunk that reached the store, so a test can count slices rather
  /// than reach for a real file.
  final Map<String, List<int>> uploads = {};

  /// The upload each device has open, or null once it is committed or dropped.
  final Map<String, String> openUploads = {};

  /// Declared lengths and the next slice expected, so this refuses a short or
  /// gapped upload the way the app's `CompanionAttachmentStore` does — the rules the api
  /// is tested against, with the real store's own test proving it keeps them.
  final Map<String, int> uploadDeclared = {};
  final Map<String, int> uploadNextSeq = {};

  /// When set, the next [RemoteHostBindings.beginAttachment] throws it.
  RemoteApiRefusal? attachmentRefusal;

  /// Uploads that became a file the desktop composer was offered.
  final List<String> committed = [];

  int discardCalls = 0;
  int _uploadCounter = 0;

  /// Every answer that actually reached the terminal. A refused one must not
  /// appear here — that is the whole point of refusing it.
  final List<({String sessionId, String decision})> approvalAnswers = [];
  final List<RemoteQuestionAnswerRequest> questionAnswers = [];
  final List<RemoteMenuAnswerRequest> menuAnswers = [];

  /// What `usage.get` answers.
  RemoteUsageSnapshot usageSnapshot = RemoteUsageSnapshot(
    accounts: const [],
    observedAt: DateTime.utc(2026, 9, 19),
  );

  /// When set, [RemoteHostBindings.answerMenu] refuses with it.
  RemoteApiRefusal? menuRefusal;
  final List<
    ({
      String deviceId,
      String token,
      String platform,
      CompanionPresence presence,
    })
  >
  pushes = [];

  /// When set, [RemoteHostBindings.answerApproval] throws this.
  RemoteApiRefusal? approvalRefusal;

  /// When set, every prompt send throws it.
  Object? promptError;

  /// What one transcript read costs. The sweep that reads every watched session
  /// is the slowest thing the host does, and how it is scheduled decides
  /// whether the phone is ever answered.
  Duration transcriptCost = Duration.zero;

  /// How many transcript reads the fake has served, so a test can watch the
  /// poll sweep run rather than infer it.
  int transcriptReads = 0;

  /// What each session's record looks like on disk *now*. Unset is a host that
  /// cannot tell — what every test that never sets it gets, and what every
  /// binding without the reading answers — so the poll reads as it always did.
  final Map<String, String> revisions = {};

  /// How many cheap readings the fake has served, so a test can tell a `stat`
  /// from a parse.
  int recordStateReads = 0;

  /// Held open, every transcript read waits here — a store big enough that the
  /// parse does not finish inside the phone's request timeout. The owner's
  /// largest is 115 MB, which is what put `session.subscribe` past it.
  Completer<void>? transcriptGate;

  /// The same for the delivery-stage lookup, which is what a snapshot push
  /// pays per session.
  Duration stageCost = Duration.zero;
  int stageReads = 0;

  /// When set, every delivery-stage lookup waits on it — a desktop that has
  /// stopped answering, held for exactly as long as the test says rather than
  /// out-waited with a [stageCost] the request timeout has to lose a race to.
  Completer<void>? stageGate;

  /// When set, every prompt send waits on it — a desktop too busy to answer,
  /// which is a different thing from a desktop that is gone.
  Completer<void>? promptGate;

  /// What `workspace.list` answers with.
  final List<RemoteWorkspaceProject> workspace = [];

  /// Every start the host actually carried out, in order. A retry that the
  /// ledger absorbs must not add a row here.
  final List<RemoteSessionStartRequest> starts = [];
  int addProjectCalls = 0;
  int resumeCalls = 0;

  /// When set, the next start throws it and is then cleared, so a test can
  /// fail one attempt and let the retry through.
  Object? startError;

  /// When set, a start waits on it — a desktop mid-launch when the link drops.
  Completer<void>? startGate;

  int _startCounter = 0;

  late final RemoteHostBindings bindings = RemoteHostBindings(
    hostName: 'TestHost',
    listSessions: () => sessions.values.toList(),
    sessionById: (id) => sessions[id],
    deliveryStageFor: (id) async {
      stageReads++;
      final gate = stageGate;
      if (gate != null) await gate.future;
      if (stageCost > Duration.zero) await Future<void>.delayed(stageCost);
      return stages[id];
    },
    readRecordState: (id) async {
      recordStateReads++;
      final revision = revisions[id];
      return (
        revision: revision,
        // The production binding can only speak for a revision it has read, so
        // an unknown one is answered by reading, exactly as before.
        activity: revision == null
            ? null
            : activities[id] ??
                  RemoteSessionActivity(sessionId: id, observedAt: observedAt),
      );
    },
    transcriptFor: (id) async {
      transcriptReads++;
      final gate = transcriptGate;
      if (gate != null) await gate.future;
      if (transcriptCost > Duration.zero) {
        await Future<void>.delayed(transcriptCost);
      }
      final messages = transcripts[id] ?? const <RemoteTranscriptMessage>[];
      return (
        page: RemoteTranscriptPage(
          sessionId: id,
          messages: List.of(messages),
          cursor: messages.length,
          absence: messages.isEmpty ? absences[id] : null,
        ),
        activity:
            activities[id] ??
            RemoteSessionActivity(sessionId: id, observedAt: observedAt),
      );
    },
    sendPrompt: (sessionId, text, {attachment}) async {
      final gate = promptGate;
      if (gate != null) await gate.future;
      if (promptError != null) throw promptError!;
      // The attachment is settled first, because the production binding
      // commits before it offers anything: a prompt whose file did not
      // arrive does not go either.
      if (attachment == null) {
        prompts.add((sessionId: sessionId, text: text));
        promptAttachments.add(null);
        return RemotePromptDelivery.sent;
      }
      final open = openUploads[attachment.deviceId];
      if (open != attachment.uploadId) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'that attachment is not waiting to be sent',
        );
      }
      final sent = uploads[attachment.uploadId]!.length;
      final declared = uploadDeclared[attachment.uploadId]!;
      if (sent != declared) {
        openUploads.remove(attachment.deviceId);
        throw RemoteApiRefusal(
          ErrorCode.badRequest,
          'only $sent of $declared bytes arrived',
        );
      }
      openUploads.remove(attachment.deviceId);
      committed.add(attachment.uploadId);
      prompts.add((sessionId: sessionId, text: text));
      promptAttachments.add(attachment.uploadId);
      // Offered to the desktop composer rather than typed in — see
      // [RemoteHostBindings.sendPrompt].
      return RemotePromptDelivery.offered;
    },
    answerApproval: (sessionId, decision) async {
      final refusal = approvalRefusal;
      if (refusal != null) throw refusal;
      approvalAnswers.add((sessionId: sessionId, decision: decision));
      return decision == 'approve' ? 'Yes (enter)' : 'No (esc)';
    },
    answerQuestion: (request) async {
      questionAnswers.add(request);
      return request.decline ? 'declined' : 'answered';
    },
    usage: () async => usageSnapshot,
    answerMenu: (request) async {
      final refusal = menuRefusal;
      if (refusal != null) throw refusal;
      menuAnswers.add(request);
      return 'option ${request.option}';
    },
    approvalEvidenceFor: (sessionId) async =>
        approvals[sessionId] ?? RemoteApprovalRequest(sessionId: sessionId),
    registerPush: (deviceId, token, platform, presence) async {
      pushes.add((
        deviceId: deviceId,
        token: token,
        platform: platform,
        presence: presence,
      ));
    },
    listWorkspace: () => List.of(workspace),
    listProjects: () => List.of(workspace),
    addProject: (name, path) async {
      addProjectCalls++;
      return RemoteWorkspaceProject(projectId: path, name: name, path: path);
    },
    resumeSession: (sessionId) async {
      resumeCalls++;
      return RemoteSessionStarted(
        sessionId: sessionId,
        title: sessions[sessionId]?.title ?? 'Resumed',
      );
    },
    beginAttachment: (deviceId, request) async {
      final refusal = attachmentRefusal;
      if (refusal != null) throw refusal;
      final id = 'up${++_uploadCounter}';
      openUploads[deviceId] = id;
      uploadDeclared[id] = request.bytes;
      uploadNextSeq[id] = 0;
      uploads[id] = <int>[];
      return const RemoteAttachmentOffer(
        uploadId: '',
        chunkBytes: kAttachmentChunkBytes,
      ).named(id);
    },
    writeAttachmentChunk: (deviceId, uploadId, seq, data) async {
      if (openUploads[deviceId] != uploadId) {
        throw const RemoteApiRefusal(
          ErrorCode.badRequest,
          'no attachment is being sent',
        );
      }
      if (uploadNextSeq[uploadId] != seq) {
        throw RemoteApiRefusal(
          ErrorCode.badRequest,
          'expected chunk ${uploadNextSeq[uploadId]}, got $seq — '
          'a slice was lost',
        );
      }
      uploads[uploadId]!.addAll(data);
      uploadNextSeq[uploadId] = seq + 1;
    },
    discardAttachment: (deviceId) async {
      discardCalls++;
      openUploads.remove(deviceId);
    },
    startSession: (request) async {
      final gate = startGate;
      if (gate != null) await gate.future;
      final failure = startError;
      if (failure != null) {
        startError = null;
        throw failure;
      }
      starts.add(request);
      final id = 'new${++_startCounter}';
      addSession(id, title: request.title ?? 'Session');
      return RemoteSessionStarted(
        sessionId: id,
        title: request.title ?? 'Session',
        permissionMode: request.permissionMode,
      );
    },
  );

  /// One project, one checkout, one agent — the smallest workspace a phone
  /// can offer a real choice from.
  void addWorkspace({
    String projectId = 'p1',
    String repositoryId = 'r1',
    String installationId = 'i1',
    bool acceptsOpeningMessage = true,
  }) {
    workspace.add(
      RemoteWorkspaceProject(
        projectId: projectId,
        name: 'PopupBits',
        path: r'C:\work',
        checkouts: [
          RemoteCheckoutOption(
            repositoryId: repositoryId,
            name: 'karmashala',
            path: r'C:\work\karmashala',
            branch: 'main',
            agents: [
              RemoteAgentOption(
                installationId: installationId,
                agentId: 'claude',
                name: 'Claude Code',
                defaultMode: 'ask',
                acceptsOpeningMessage: acceptsOpeningMessage,
                permissionModes: const [
                  RemotePermissionOption(
                    mode: 'ask',
                    label: 'Ask every time',
                    summary: 'Claude Code is told to use it.',
                    selectable: true,
                  ),
                  RemotePermissionOption(
                    mode: 'bypass',
                    label: 'Bypass (full autonomy)',
                    summary: 'Claude Code is told to use it.',
                    selectable: true,
                    dangerous: true,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  void addSession(
    String id, {
    String title = 'Fix the tests',
    String status = 'running',
    String? agentLabel,
    String? whereabouts,
    String? lastActivityAt,
    bool imported = false,
    String? attention,
    RemoteAttachmentSupport? attachments = const RemoteAttachmentSupport(
      mediaTypes: ['image/png', 'image/jpeg'],
      maxBytes: kMaxAttachmentBytes,
    ),
  }) {
    sessions[id] = RemoteSessionSnapshot(
      sessionId: id,
      title: title,
      status: status,
      agentLabel: agentLabel,
      whereabouts: whereabouts,
      lastActivityAt: lastActivityAt,
      imported: imported,
      attention: attention,
      attachments: attachments,
    );
  }

  /// The desktop's own state while a prompt is up, and after it is answered.
  /// The host reads exactly this to decide whether there is anything left to
  /// answer, so a test moves it rather than scripting a separate flag.
  void setAwaitingApproval(String id, {bool waiting = true}) {
    final session = sessions[id];
    if (session == null) return;
    sessions[id] = session.copyWith(
      attention: waiting ? kAttentionNeedsApproval : null,
      clearAttention: !waiting,
    );
  }
}

/// The id [fakeDevice] carries, named so a test can address the same device
/// the api will — an upload belongs to a link, so the id is the key.
const String kFakeDeviceId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

/// A paired device carrying [capabilities], with a throwaway key.
PairedDevice fakeDevice({
  CapabilitySet? capabilities,
  String id = kFakeDeviceId,
}) => PairedDevice(
  id: id,
  name: 'OPPO',
  deviceKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
  capabilities: capabilities ?? CapabilitySet.all,
  generation: 1,
  createdAt: DateTime.utc(2026, 8, 31),
);

extension on RemoteAttachmentOffer {
  RemoteAttachmentOffer named(String uploadId) =>
      RemoteAttachmentOffer(uploadId: uploadId, chunkBytes: chunkBytes);
}
