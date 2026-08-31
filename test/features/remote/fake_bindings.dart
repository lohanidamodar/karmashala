import 'dart:async';
import 'dart:typed_data';

import 'package:chitragupta/src/features/remote/application/host_bindings.dart';
import 'package:chitragupta/src/features/remote/domain/paired_device.dart';
import 'package:chitragupta/src/features/remote/domain/remote_payloads.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';

/// In-memory bindings: sessions, transcripts and recorded actions, with no
/// providers, processes or terminals anywhere near them.
class FakeRemoteBindings {
  final Map<String, RemoteSessionSnapshot> sessions = {};
  final Map<String, List<RemoteTranscriptMessage>> transcripts = {};
  final Map<String, String?> stages = {};
  final Map<String, RemoteApprovalRequest> approvals = {};
  final List<({String sessionId, String text})> prompts = [];
  final List<({String deviceId, String token, String platform})> pushes = [];

  /// When set, [RemoteHostBindings.answerApproval] throws this.
  RemoteApiRefusal? approvalRefusal;

  /// When set, every prompt send throws it.
  Object? promptError;

  /// When set, every prompt send waits on it — a desktop too busy to answer,
  /// which is a different thing from a desktop that is gone.
  Completer<void>? promptGate;

  late final RemoteHostBindings bindings = RemoteHostBindings(
    hostName: 'TestHost',
    listSessions: () => sessions.values.toList(),
    sessionById: (id) => sessions[id],
    deliveryStageFor: (id) async => stages[id],
    transcriptFor: (id) async {
      final messages = transcripts[id] ?? const <RemoteTranscriptMessage>[];
      return RemoteTranscriptPage(
        sessionId: id,
        messages: List.of(messages),
        cursor: messages.length,
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
      return decision == 'approve' ? 'Yes (enter)' : 'No (esc)';
    },
    approvalEvidenceFor: (sessionId) async =>
        approvals[sessionId] ?? RemoteApprovalRequest(sessionId: sessionId),
    registerPush: (deviceId, token, platform) async {
      pushes.add((deviceId: deviceId, token: token, platform: platform));
    },
  );

  void addSession(
    String id, {
    String title = 'Fix the tests',
    String status = 'running',
    String? agentLabel,
    String? whereabouts,
    String? lastActivityAt,
    bool imported = false,
  }) {
    sessions[id] = RemoteSessionSnapshot(
      sessionId: id,
      title: title,
      status: status,
      agentLabel: agentLabel,
      whereabouts: whereabouts,
      lastActivityAt: lastActivityAt,
      imported: imported,
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
