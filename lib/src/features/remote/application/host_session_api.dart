/// One paired device's view of the session API: decodes its requests, enforces
/// its capability bitset per frame, and pushes it events.
///
/// Enforcement order is fixed: version, then known type, then origin, then
/// capability, then the handler. A missing capability is a protocol `error`,
/// never an exception — a hostile or outdated phone can be refused forever
/// without costing the host anything.
library;

import 'dart:convert';

import '../domain/paired_device.dart';
import '../domain/remote_payloads.dart';
import '../protocol.dart';
import 'host_bindings.dart';

/// Seals and transmits one frame for the device this api serves. Supplied by
/// the service, which owns the channel and the transport.
typedef RemoteSend =
    Future<void> Function(
      FrameType type, {
      String? id,
      Map<String, Object?> payload,
    });

class HostSessionApi {
  HostSessionApi({
    required this.device,
    required this.bindings,
    required RemoteSend send,
    this.onLog,
    // ignore: prefer_initializing_formals — named `send` for callers.
  }) : _send = send;

  final PairedDevice device;
  final RemoteHostBindings bindings;
  final RemoteSend _send;

  /// Lifecycle only — never called with payload content.
  final void Function(String message)? onLog;

  final Set<String> _subscribed = <String>{};
  final Map<String, int> _transcriptCursors = <String, int>{};
  final Map<String, String> _lastSnapshots = <String, String>{};

  Set<String> get subscribedSessions => Set.unmodifiable(_subscribed);

  /// The `host.status` greeting: the supported version range, so a companion
  /// outside it knows to update.
  Future<void> sendHostStatus() => _send(
    FrameType.hostStatus,
    payload: RemoteHostStatus(
      versions: kSupportedVersions,
      hostName: bindings.hostName,
    ).toJson(),
  );

  /// Handles one decoded envelope from the companion.
  Future<void> handleEnvelope(Envelope envelope) async {
    if (!kSupportedVersions.contains(envelope.version)) {
      await _error(
        envelope.id,
        ErrorCode.unsupportedVersion,
        'this host accepts $kSupportedVersions',
      );
      // Tell it what to update to, per the design's handshake.
      await sendHostStatus();
      return;
    }
    final type = envelope.knownType;
    if (type == null) {
      await _error(envelope.id, ErrorCode.unknownType, 'unknown frame type');
      return;
    }
    if (!type.sentBy(FrameOrigin.companion)) {
      await _error(
        envelope.id,
        ErrorCode.badRequest,
        '${type.wire} is not a companion frame',
      );
      return;
    }
    if (!device.capabilities.allows(type)) {
      await _error(
        envelope.id,
        ErrorCode.notPermitted,
        'this device was not granted ${type.capability?.wire}',
      );
      return;
    }
    try {
      switch (type) {
        case FrameType.sessionsList:
          final rows = <Map<String, Object?>>[];
          for (final snapshot in bindings.listSessions()) {
            rows.add((await _withStage(snapshot)).toJson());
          }
          await _result(envelope.id, {'sessions': rows});
        case FrameType.sessionSubscribe:
          final sessionId = _requireSession(envelope);
          _subscribed.add(sessionId);
          if (device.capabilities.has(Capability.readTranscript)) {
            // Prime the cursor to *now*: `appended` carries what happens from
            // here on; history is the phone's `transcript.get` to make.
            try {
              _transcriptCursors[sessionId] = (await bindings.transcriptFor(
                sessionId,
              )).cursor;
            } on Object {
              _transcriptCursors[sessionId] = 0;
            }
          }
          await _result(envelope.id, const {});
          await _pushSnapshot(sessionId);
        case FrameType.sessionUnsubscribe:
          final sessionId = _requireString(envelope, 'sessionId');
          _subscribed.remove(sessionId);
          _transcriptCursors.remove(sessionId);
          _lastSnapshots.remove(sessionId);
          await _result(envelope.id, const {});
        case FrameType.transcriptGet:
          final sessionId = _requireSession(envelope);
          final after = envelope.payload['after'];
          final from = after is int && after > 0 ? after : 0;
          final page = await bindings.transcriptFor(sessionId);
          final start = from > page.messages.length
              ? page.messages.length
              : from;
          await _result(
            envelope.id,
            RemoteTranscriptPage(
              sessionId: sessionId,
              messages: page.messages.sublist(start),
              cursor: page.cursor,
            ).toJson(),
          );
        case FrameType.promptSend:
          final sessionId = _requireSession(envelope);
          final text = _requireString(envelope, 'text');
          await bindings.sendPrompt(sessionId, text);
          await _result(envelope.id, const {});
        case FrameType.approvalAnswer:
          final sessionId = _requireSession(envelope);
          final decision = _requireString(envelope, 'decision');
          if (decision != 'approve' && decision != 'deny') {
            throw const RemoteApiRefusal(
              ErrorCode.badRequest,
              'decision must be approve or deny',
            );
          }
          final pressed = await bindings.answerApproval(sessionId, decision);
          await _result(envelope.id, {'pressed': pressed});
        case FrameType.notificationsRegister:
          final token = _requireString(envelope, 'token');
          final platform = _requireString(envelope, 'platform');
          await bindings.registerPush(device.id, token, platform);
          await _result(envelope.id, const {});
        // Host-only types cannot reach here: sentBy refused them above.
        case FrameType.sessionChanged:
        case FrameType.transcriptAppended:
        case FrameType.approvalRequested:
        case FrameType.hostStatus:
        case FrameType.result:
        case FrameType.error:
          await _error(
            envelope.id,
            ErrorCode.badRequest,
            '${type.wire} is not a request',
          );
      }
    } on RemoteApiRefusal catch (refusal) {
      await _error(envelope.id, refusal.code, refusal.message);
    } on Object catch (error) {
      // A handler bug must refuse one request, never drop the connection.
      onLog?.call('handler for ${type.wire} failed: $error');
      await _error(
        envelope.id,
        ErrorCode.internal,
        'the host could not handle this request',
      );
    }
  }

  /// Re-evaluates every subscribed session and sends `session.changed` for
  /// the ones whose snapshot moved.
  Future<void> pushSessionsChanged() async {
    for (final sessionId in _subscribed.toList()) {
      await _pushSnapshot(sessionId);
    }
  }

  /// Folds the delivery stage into [snapshot] — the same lookup the desktop
  /// strip pays. Imported history has no delivery line, so it is skipped.
  Future<RemoteSessionSnapshot> _withStage(
    RemoteSessionSnapshot snapshot,
  ) async {
    if (snapshot.imported) return snapshot;
    String? stage;
    try {
      stage = await bindings.deliveryStageFor(snapshot.sessionId);
    } on Object {
      stage = null; // "could not tell" is a first-class answer.
    }
    return stage == null ? snapshot : snapshot.copyWith(stage: stage);
  }

  Future<void> _pushSnapshot(String sessionId) async {
    final base = bindings.sessionById(sessionId);
    if (base == null) return;
    final snapshot = await _withStage(base);
    final encoded = jsonEncode(snapshot.toJson());
    if (_lastSnapshots[sessionId] == encoded) return;
    _lastSnapshots[sessionId] = encoded;
    await _send(FrameType.sessionChanged, payload: snapshot.toJson());
  }

  /// Sends the transcript growth of every subscribed session since the last
  /// poll. A no-op without the `read_transcript` capability.
  Future<void> pollTranscripts() async {
    if (!device.capabilities.has(Capability.readTranscript)) return;
    for (final sessionId in _subscribed.toList()) {
      final RemoteTranscriptPage page;
      try {
        page = await bindings.transcriptFor(sessionId);
      } on Object {
        continue;
      }
      final cursor = _transcriptCursors[sessionId] ?? 0;
      if (page.cursor <= cursor || cursor > page.messages.length) {
        _transcriptCursors[sessionId] = page.cursor;
        continue;
      }
      _transcriptCursors[sessionId] = page.cursor;
      await _send(
        FrameType.transcriptAppended,
        payload: RemoteTranscriptPage(
          sessionId: sessionId,
          messages: page.messages.sublist(cursor),
          cursor: page.cursor,
        ).toJson(),
      );
    }
  }

  /// Sends `approval.requested` with the Loop-49 evidence. Gated on the
  /// `approve` capability — the event exists so the holder can act on it —
  /// and deliberately not on subscription: an approval is exactly the news a
  /// phone in a pocket is paired for.
  Future<void> pushApprovalRequested(String sessionId) async {
    if (!device.capabilities.has(Capability.approve)) return;
    RemoteApprovalRequest request;
    try {
      request = await bindings.approvalEvidenceFor(sessionId);
    } on Object {
      request = RemoteApprovalRequest(sessionId: sessionId);
    }
    await _send(FrameType.approvalRequested, payload: request.toJson());
  }

  String _requireString(Envelope envelope, String key) {
    final value = envelope.payload[key];
    if (value is! String || value.isEmpty) {
      throw RemoteApiRefusal(ErrorCode.badRequest, 'missing $key');
    }
    return value;
  }

  String _requireSession(Envelope envelope) {
    final sessionId = _requireString(envelope, 'sessionId');
    if (bindings.sessionById(sessionId) == null) {
      throw const RemoteApiRefusal(ErrorCode.notFound, 'no such session');
    }
    return sessionId;
  }

  Future<void> _result(String? id, Map<String, Object?> payload) =>
      _send(FrameType.result, id: id, payload: payload);

  Future<void> _error(String? id, ErrorCode code, String message) => _send(
    FrameType.error,
    id: id,
    payload: {'code': code.wire, 'message': message},
  );
}
