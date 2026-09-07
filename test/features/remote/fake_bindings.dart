import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala/src/features/remote/application/host_bindings.dart';
import 'package:karmashala/src/features/remote/domain/paired_device.dart';
import 'package:karmashala/src/features/remote/domain/remote_payloads.dart';
import 'package:karmashala/src/features/remote/protocol.dart';

/// In-memory bindings: sessions, transcripts and recorded actions, with no
/// providers, processes or terminals anywhere near them.
class FakeRemoteBindings {
  final Map<String, RemoteSessionSnapshot> sessions = {};
  final Map<String, List<RemoteTranscriptMessage>> transcripts = {};

  /// Why a session's transcript is empty, for a host that can say — the
  /// `agentSupportsChatView` refusal, as the production bindings report it.
  final Map<String, RemoteTranscriptAbsence> absences = {};
  final Map<String, String?> stages = {};
  final Map<String, RemoteApprovalRequest> approvals = {};
  final List<({String sessionId, String text})> prompts = [];

  /// Every answer that actually reached the terminal. A refused one must not
  /// appear here — that is the whole point of refusing it.
  final List<({String sessionId, String decision})> approvalAnswers = [];
  final List<({String deviceId, String token, String platform})> pushes = [];

  /// When set, [RemoteHostBindings.answerApproval] throws this.
  RemoteApiRefusal? approvalRefusal;

  /// When set, every prompt send throws it.
  Object? promptError;

  /// What one transcript read costs. A real one reads a session's scrollback,
  /// and the desktop this matters on has a dozen sessions being watched — so
  /// the sweep that reads them all is the slowest thing the host does, and how
  /// it is scheduled decides whether the phone is ever answered.
  Duration transcriptCost = Duration.zero;

  /// How many transcript reads the fake has served, so a test can watch the
  /// poll sweep run rather than infer it.
  int transcriptReads = 0;

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
  /// out-waited with a [stageCost] the phone's request timeout has to lose a
  /// race to. The margin between those two numbers was tens of milliseconds
  /// wide and decided several `--concurrency=4` runs.
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
    transcriptFor: (id) async {
      transcriptReads++;
      final gate = transcriptGate;
      if (gate != null) await gate.future;
      if (transcriptCost > Duration.zero) {
        await Future<void>.delayed(transcriptCost);
      }
      final messages = transcripts[id] ?? const <RemoteTranscriptMessage>[];
      return RemoteTranscriptPage(
        sessionId: id,
        messages: List.of(messages),
        cursor: messages.length,
        absence: messages.isEmpty ? absences[id] : null,
      );
    },
    sendPrompt: (sessionId, text) async {
      final gate = promptGate;
      if (gate != null) await gate.future;
      if (promptError != null) throw promptError!;
      prompts.add((sessionId: sessionId, text: text));
    },
    answerApproval: (sessionId, decision) async {
      final refusal = approvalRefusal;
      if (refusal != null) throw refusal;
      approvalAnswers.add((sessionId: sessionId, decision: decision));
      return decision == 'approve' ? 'Yes (enter)' : 'No (esc)';
    },
    approvalEvidenceFor: (sessionId) async =>
        approvals[sessionId] ?? RemoteApprovalRequest(sessionId: sessionId),
    registerPush: (deviceId, token, platform) async {
      pushes.add((deviceId: deviceId, token: token, platform: platform));
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

/// A paired device carrying [capabilities], with a throwaway key.
PairedDevice fakeDevice({
  CapabilitySet? capabilities,
  String id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
}) => PairedDevice(
  id: id,
  name: 'OPPO',
  deviceKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
  capabilities: capabilities ?? CapabilitySet.all,
  generation: 1,
  createdAt: DateTime.utc(2026, 8, 31),
);
