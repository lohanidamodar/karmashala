/// One paired device's view of the session API: decodes its requests, enforces
/// its capability bitset per frame, and pushes it events. Enforcement order is
/// fixed — version, type, origin, capability, handler — and a missing capability
/// is a protocol `error`, never an exception.
library;

import 'dart:convert';

import '../util/bounded_text.dart';
import '../domain/companion_presence.dart';
import '../domain/paired_device.dart';
import '../domain/remote_payloads.dart';
import '../protocol.dart';
import 'host_bindings.dart';
import 'session_start_ledger.dart';

/// Seals and transmits one frame for the device this api serves, and answers
/// whether a transport took it. **False means the frame is gone**, not delayed,
/// so anything this api remembers telling the phone is recorded after a `true`.
typedef RemoteSend =
    Future<bool> Function(
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
    this.relays,
    this.lanHint,
    this.onStreamAck,
    SessionStartLedger<RemoteSessionStarted>? startLedger,
    SessionStartLedger<RemoteSessionStarted>? resumeLedger,
    SessionStartLedger<RemoteWorkspaceProject>? projectLedger,
    SessionStartLedger<RemotePromptDelivery>? promptLedger,
    // ignore: prefer_initializing_formals — named `send` for callers.
  }) : _send = send,
       _starts = startLedger ?? SessionStartLedger<RemoteSessionStarted>(),
       _resumes = resumeLedger ?? SessionStartLedger<RemoteSessionStarted>(),
       _projects =
           projectLedger ?? SessionStartLedger<RemoteWorkspaceProject>(),
       _prompts = promptLedger ?? SessionStartLedger<RemotePromptDelivery>();

  /// The device this api serves. **Not final**: permissions edited on the
  /// desktop are enforced from the next frame, on the link the phone already
  /// holds — re-pairing to widen a grant is what this replaces.
  PairedDevice device;

  final RemoteHostBindings bindings;
  final RemoteSend _send;

  /// What this device's `session.start` frames have already produced. Supplied
  /// by the caller so it can outlive one connection — see [SessionStartLedger].
  final SessionStartLedger<RemoteSessionStarted> _starts;
  final SessionStartLedger<RemoteSessionStarted> _resumes;
  final SessionStartLedger<RemoteWorkspaceProject> _projects;

  /// What each keyed `prompt.send` did, so a retry of an unanswered send is
  /// answered from here rather than typed into the agent a second time.
  final SessionStartLedger<RemotePromptDelivery> _prompts;

  /// Where this host can be met right now, read fresh at every announcement so
  /// a relay switched on mid-session reaches the phone at once.
  final List<Uri> Function()? relays;

  /// `host:port` of the direct LAN listener, when there is a LAN address to
  /// name — a discovery hint the phone may try, never an identity.
  final String? Function()? lanHint;

  /// Lifecycle only — never called with payload content.
  final void Function(String message)? onLog;

  /// Takes a `stream.ack`. Null means this host does not flow-control, and
  /// then `host.status` does not invite acks either.
  final void Function(int seq, bool? watching)? onStreamAck;

  final Set<String> _subscribed = <String>{};

  /// The lowest `inputSeq` still acceptable on this link.
  int _nextInput = 0;

  /// Every session this device has been shown — listed, subscribed to, or
  /// announced. Null until its first `sessions.list`: before that, the list it
  /// is about to ask for carries everything, and announcing would only race it.
  Set<String>? _shown;

  final Map<String, int> _transcriptCursors = <String, int>{};

  /// Sessions this device has been told are waiting on it. Kept so
  /// [reconcileApproval] can retire a card it was shown before a reconnect.
  final Set<String> _announcedApprovals = <String>{};

  /// What each announced approval asked — see [recheckApproval].
  final Map<String, String> _announcedAsks = <String, String>{};

  /// When each watched session may next be read, on [_uptime]'s scale. The next
  /// poll waits [_pollBackoffFactor] times what the last read cost, so an
  /// expensive transcript is read less often instead of starving the link.
  final Map<String, Duration> _pollNotBefore = <String, Duration>{};

  static const int _pollBackoffFactor = 4;

  /// Below this a read is not what is starving anything, so it earns no wait.
  static const Duration _pollBackoffFloor = Duration(milliseconds: 20);

  /// The record revision each watched session was last **read** at. Per device
  /// on purpose: a revision is what this phone has been served up to, so
  /// another device's read must never consume this one's delta.
  final Map<String, String> _readRevisions = <String, String>{};

  final Stopwatch _uptime = Stopwatch()..start();
  final Map<String, String> _lastSnapshots = <String, String>{};

  /// The activity each watched session was last **told** to have, encoded.
  /// `observedAt` is deliberately not compared: it moves on every read, and a
  /// frame per poll saying "still the same, later" is the churn this prevents.
  final Map<String, String> _lastActivity = <String, String>{};

  Set<String> get subscribedSessions => Set.unmodifiable(_subscribed);

  /// Forgets which snapshots and activity the phone was told, so the next
  /// sweep re-sends current state — for a stream that failed closed, where
  /// frames that left may never have been read.
  void forgetDelivered() {
    _lastSnapshots.clear();
    _lastActivity.clear();
  }

  /// The `host.status` greeting: the supported version range, where this host
  /// can be reached — so a phone's saved relay set heals over the live link —
  /// and what this device is granted now, so a permission edited here reaches
  /// the phone without re-pairing.
  Future<void> sendHostStatus() => _send(
    FrameType.hostStatus,
    payload: RemoteHostStatus(
      versions: kSupportedVersions,
      hostName: bindings.hostName,
      relays: relays?.call() ?? const [],
      lanHint: lanHint?.call(),
      capabilities: device.capabilities,
      streamAcks: onStreamAck != null,
    ).toJson(),
  );

  /// Tells the companion its pairing is gone, before the link is taken away.
  /// Over a relay the phone's socket outlives the revoke, and silence reads
  /// exactly like a busy desktop.
  Future<void> sendPairingRevoked() => _send(FrameType.pairingRevoked);

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
    // Before the capability check, so every numbered frame is judged here,
    // and a refused one still moves the count on.
    if (type.isInput) {
      final inputSeq = envelope.payload['inputSeq'];
      if (inputSeq is int) {
        if (inputSeq < _nextInput) {
          await _send(
            FrameType.error,
            id: envelope.id,
            payload: {
              'code': ErrorCode.outOfOrder.wire,
              'message': 'input $inputSeq arrived after a later one',
              'expected': _nextInput,
            },
          );
          return;
        }
        // A gap is a lost frame, not a duplicate: it is let through.
        _nextInput = inputSeq + 1;
      }
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
          final shown = _shown ??= <String>{};
          for (final snapshot in await bindings.listSessions()) {
            rows.add((await _withStage(snapshot)).toJson());
            shown.add(snapshot.sessionId);
          }
          await _result(envelope.id, {'sessions': rows});
        case FrameType.sessionSubscribe:
          final sessionId = await _requireSession(envelope);
          _subscribed.add(sessionId);
          _shown?.add(sessionId);
          // **Nothing here reads the transcript.** It used to, to prime the
          // cursor to *now*; the priming happens on the first poll instead —
          // see [pollTranscript], which has to read the transcript anyway.
          await _result(envelope.id, const {});
          await _pushSnapshot(sessionId);
          // `approval.requested` goes out once, as a session starts waiting. A
          // phone that was asleep then — or is on a link that replaced the one
          // it went out on — would read "needs you" with nothing to act on.
          if (await _awaitingApproval(sessionId) &&
              !_announcedApprovals.contains(sessionId)) {
            await pushApprovalRequested(sessionId);
          }
        case FrameType.sessionUnsubscribe:
          final sessionId = _requireString(envelope, 'sessionId');
          _subscribed.remove(sessionId);
          _transcriptCursors.remove(sessionId);
          _pollNotBefore.remove(sessionId);
          _readRevisions.remove(sessionId);
          _lastSnapshots.remove(sessionId);
          _lastActivity.remove(sessionId);
          await _result(envelope.id, const {});
        case FrameType.transcriptGet:
          final sessionId = await _requireSession(envelope);
          final after = envelope.payload['after'];
          final from = after is int && after > 0 ? after : 0;
          final page = (await bindings.transcriptFor(sessionId)).page;
          // Opened at the end, and bounded: a long transcript cannot be carried
          // in one frame. `after` still pages for an earlier window.
          final total = page.messages.length;
          final start = from > 0
              ? (from > total ? total : from)
              : (total > kRemoteTranscriptPageMax
                    ? total - kRemoteTranscriptPageMax
                    : 0);
          // **Bounded at both ends now.** `after` used to answer with the whole
          // remainder, which is a frame the link could not carry; it gets a
          // page, and `hasNewer` is what tells it to ask again.
          final end = total - start > kRemoteTranscriptPageMax
              ? start + kRemoteTranscriptPageMax
              : total;
          // Serving history is also what marks this session as *watched*: the
          // phone asks for it only for the session it has open.
          // The window's end, not the whole count — the same number only for a
          // tail read.
          _transcriptCursors[sessionId] = end;
          await _result(
            envelope.id,
            RemoteTranscriptPage(
              sessionId: sessionId,
              messages: collapseTaskNotifications(
                page.messages.sublist(start, end),
              ),
              cursor: end,
              omitted: start,
              hasNewer: end < total,
              // Carried, not re-derived: this rebuilds the page to window it,
              // and the reason is what tells the phone which nothing it sees.
              absence: page.absence,
            ).toJson(),
          );
        case FrameType.sessionActivity:
          // The phone asking outright, on opening a session and after a
          // reconnect, where the frames it missed cannot be replayed.
          final sessionId = await _requireSession(envelope);
          final activity = (await bindings.transcriptFor(sessionId)).activity;
          _lastActivity[sessionId] = _activityKey(activity);
          await _result(envelope.id, activity.toJson());
        case FrameType.promptSend:
          final sessionId = await _requireSession(envelope);
          final text = _requireString(envelope, 'text');
          final attachmentId = _optionalString(envelope, 'attachment');
          // Belt and braces on the bit: a prompt naming an attachment is the
          // frame that would *use* it, and an older pairing holds `send_prompt`.
          if (attachmentId != null &&
              !device.capabilities.has(Capability.sendAttachment)) {
            throw const RemoteApiRefusal(
              ErrorCode.notPermitted,
              'this device was not granted send_attachment',
            );
          }
          // Optional: a phone that predates the key is typed for on every
          // frame, exactly as before.
          final key = _optionalString(envelope, 'requestId');
          if (key != null && key.length > kMaxSessionStartKeyLength) {
            throw const RemoteApiRefusal(
              ErrorCode.badRequest,
              'requestId is too long',
            );
          }
          Future<RemotePromptDelivery> send() => bindings.sendPrompt(
            sessionId,
            text,
            attachment: attachmentId == null
                ? null
                : (deviceId: device.id, uploadId: attachmentId),
          );
          final replayed = key != null && _prompts.holds(key);
          final delivery = key == null
              ? await send()
              : await _prompts.once(key, send);
          await _result(envelope.id, {
            // Only when it is not what every build before this one meant, so
            // an ordinary prompt's result keeps its old shape on the wire.
            if (delivery == RemotePromptDelivery.offered)
              'delivery': delivery.wire,
            if (replayed) 'replayed': true,
          });
        case FrameType.attachmentBegin:
          // Re-read here rather than trusted from the row the phone last saw:
          // a row can be minutes old, and the agent behind it swapped since.
          final sessionId = await _requireSession(envelope);
          final request = RemoteAttachmentBegin.fromJson({
            ...envelope.payload,
            'sessionId': sessionId,
          });
          await _checkAcceptable(sessionId, request);
          await _result(
            envelope.id,
            (await bindings.beginAttachment(device.id, request)).toJson(),
          );
        case FrameType.attachmentChunk:
          final uploadId = _requireString(envelope, 'uploadId');
          final seq = envelope.payload['seq'];
          final data = envelope.payload['data'];
          if (seq is! int || seq < 0 || data is! String) {
            throw const RemoteApiRefusal(
              ErrorCode.badRequest,
              'a chunk needs a seq and its data',
            );
          }
          final List<int> bytes;
          try {
            bytes = base64Decode(data);
          } on FormatException {
            throw const RemoteApiRefusal(
              ErrorCode.badRequest,
              'a chunk must be base64',
            );
          }
          await bindings.writeAttachmentChunk(device.id, uploadId, seq, bytes);
          // Answered so the phone knows the slice landed before it sends the
          // next: the outbound queue drops its oldest frame under pressure.
          await _result(envelope.id, const {});
        case FrameType.approvalAnswer:
          final sessionId = await _requireSession(envelope);
          final decision = _requireString(envelope, 'decision');
          if (decision != 'approve' && decision != 'deny') {
            throw const RemoteApiRefusal(
              ErrorCode.badRequest,
              'decision must be approve or deny',
            );
          }
          // The reverse race: the desktop answered a moment ago and applying
          // this would type a key into whatever prompt is there NOW. Refused on
          // the session's attention, the fact the desktop's own card is drawn from.
          if (!await _awaitingApproval(sessionId)) {
            throw const RemoteApiRefusal(
              // Not a new error code: `tryParse` on an older companion answers
              // null for a wire word it has never seen.
              ErrorCode.badRequest,
              'this approval has already been answered',
            );
          }
          final pressed = await bindings.answerApproval(sessionId, decision);
          // Told, not inferred — and told before the result, so the phone
          // that asked has the outcome even if it stops listening after it.
          await _sendApprovalResolved(
            sessionId,
            decision == 'approve'
                ? RemoteApprovalOutcome.approved
                : RemoteApprovalOutcome.denied,
          );
          await _result(envelope.id, {'pressed': pressed});
        case FrameType.questionAnswer:
          final RemoteQuestionAnswerRequest request;
          try {
            request = RemoteQuestionAnswerRequest.fromJson(envelope.payload);
          } on ProtocolException catch (error) {
            throw RemoteApiRefusal(ErrorCode.badRequest, error.message);
          }
          // The same race the approval refuses: the question may have been
          // answered at the desk a moment ago, and these keys would land in
          // whatever is on screen now.
          if (!await _awaitingApproval(request.sessionId)) {
            throw const RemoteApiRefusal(
              ErrorCode.badRequest,
              'this question has already been answered',
            );
          }
          final done = await bindings.answerQuestion(request);
          await _sendApprovalResolved(
            request.sessionId,
            request.decline
                ? RemoteApprovalOutcome.denied
                : RemoteApprovalOutcome.answered,
          );
          await _result(envelope.id, {'done': done});
        case FrameType.menuAnswer:
          final RemoteMenuAnswerRequest request;
          try {
            request = RemoteMenuAnswerRequest.fromJson(envelope.payload);
          } on ProtocolException catch (error) {
            throw RemoteApiRefusal(ErrorCode.badRequest, error.message);
          }
          if (!await _awaitingApproval(request.sessionId)) {
            throw const RemoteApiRefusal(
              ErrorCode.badRequest,
              'this prompt has already been answered',
            );
          }
          final chosen = await bindings.answerMenu(request);
          await _sendApprovalResolved(
            request.sessionId,
            RemoteApprovalOutcome.answered,
          );
          await _result(envelope.id, {'chosen': chosen});
        case FrameType.usageGet:
          await _result(envelope.id, (await bindings.usage()).toJson());
        case FrameType.notesGet:
          await _result(envelope.id, (await bindings.notes()).toJson());
        case FrameType.notificationsRegister:
          final token = _requireString(envelope, 'token');
          final platform = _requireString(envelope, 'platform');
          // Additive and never required: an old companion sends neither field.
          // The value goes to `PushFanout` and reaches nothing on this api.
          await bindings.registerPush(
            device.id,
            token,
            platform,
            CompanionPresence.fromRegister(envelope.payload),
          );
          await _result(envelope.id, const {});
        case FrameType.workspaceList:
          await _result(envelope.id, {
            'projects': [
              for (final project in await bindings.listWorkspace())
                project.toJson(),
            ],
          });
        case FrameType.projectsList:
          await _result(envelope.id, {
            'projects': [
              // Encoded whole, then the one field this list does not carry is
              // removed. Naming the fields to keep is what silently dropped
              // `environmentId` and `environmentKind` when they were added —
              // the phone then keyed projects by badge and sessions by id, and
              // drew one machine as two.
              for (final project in await bindings.listProjects())
                project.toJson()..remove('checkouts'),
            ],
          });
        case FrameType.projectAdd:
          final key = _requireString(envelope, 'requestId');
          if (key.length > kMaxSessionStartKeyLength) {
            throw const RemoteApiRefusal(
              ErrorCode.badRequest,
              'requestId is too long',
            );
          }
          final name = _requireString(envelope, 'name');
          final path = _requireString(envelope, 'path');
          final replayed = _projects.holds(key);
          final project = await _projects.once(
            key,
            () => bindings.addProject(name, path),
          );
          await _result(envelope.id, {
            ...project.toJson(),
            if (replayed) 'replayed': true,
          });
        case FrameType.sessionStart:
          // The idempotency key, first: a start that cannot be recognised on a
          // second delivery is the one request this api must not take on faith.
          final key = _requireString(envelope, 'requestId');
          if (key.length > kMaxSessionStartKeyLength) {
            throw const RemoteApiRefusal(
              ErrorCode.badRequest,
              'requestId is too long',
            );
          }
          final request = RemoteSessionStartRequest(
            repositoryId: _requireString(envelope, 'repositoryId'),
            installationId: _requireString(envelope, 'installationId'),
            permissionMode: _requireString(envelope, 'permissionMode'),
            title: _optionalString(envelope, 'title'),
            message: _optionalString(envelope, 'message'),
          );
          final replayed = _starts.holds(key);
          final started = await _starts.once(
            key,
            () => bindings.startSession(request),
          );
          await _result(envelope.id, {
            ...started.toJson(),
            if (replayed) 'replayed': true,
          });
        case FrameType.sessionResume:
          final key = _requireString(envelope, 'requestId');
          if (key.length > kMaxSessionStartKeyLength) {
            throw const RemoteApiRefusal(
              ErrorCode.badRequest,
              'requestId is too long',
            );
          }
          final sessionId = _requireString(envelope, 'sessionId');
          final replayed = _resumes.holds(key);
          final resumed = await _resumes.once(
            key,
            () => bindings.resumeSession(sessionId),
          );
          await _result(envelope.id, {
            ...resumed.toJson(),
            if (replayed) 'replayed': true,
          });
        case FrameType.sessionOptions:
          final sessionId = await _requireSession(envelope);
          await _result(
            envelope.id,
            (await bindings.sessionOptions(sessionId)).toJson(),
          );
        case FrameType.sessionConfigure:
          final sessionId = await _requireSession(envelope);
          ({String? id})? field(String key) {
            if (!envelope.payload.containsKey(key)) return null;
            final value = envelope.payload[key];
            if (value != null && value is! String) {
              throw RemoteApiRefusal(ErrorCode.badRequest, 'bad $key');
            }
            final id = value as String?;
            return (id: id == null || id.isEmpty ? null : id);
          }
          final model = field('model');
          final permission = field('permission');
          if (model == null && permission == null) {
            throw const RemoteApiRefusal(
              ErrorCode.badRequest,
              'nothing to change',
            );
          }
          final outcome = await bindings.configureSession(
            sessionId,
            model: model,
            permission: permission,
          );
          await _result(envelope.id, {'outcome': outcome.wire});
        case FrameType.streamAck:
          // Never answered: an ack for an ack would be a stream of its own.
          final seq = envelope.payload['seq'];
          final watching = envelope.payload['watching'];
          if (seq is int && seq >= 0) {
            onStreamAck?.call(seq, watching is bool ? watching : null);
          }
        // Host-only types cannot reach here: sentBy refused them above.
        case FrameType.sessionChanged:
        case FrameType.transcriptAppended:
        case FrameType.approvalRequested:
        case FrameType.approvalResolved:
        case FrameType.hostStatus:
        case FrameType.pairingRevoked:
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
      await pushSessionChanged(sessionId);
    }
  }

  /// Announces every session this device has never been shown. Only subscribed
  /// sessions are pushed otherwise, and a phone subscribes only to what it listed.
  Future<void> pushNewSessions() async {
    final shown = _shown;
    if (shown == null) return;
    if (!device.capabilities.has(Capability.viewSessions)) return;
    for (final snapshot in await bindings.listSessions()) {
      if (shown.contains(snapshot.sessionId)) continue;
      final full = await _withStage(snapshot);
      // Written down only once it went out, so a dropped one is tried again.
      if (await _send(FrameType.sessionChanged, payload: full.toJson())) {
        shown.add(snapshot.sessionId);
      }
    }
  }

  /// The same, for ONE session — so the caller can chain them separately and
  /// leave room between them for a frame the user is waiting on.
  Future<void> pushSessionChanged(String sessionId) async {
    if (!_subscribed.contains(sessionId)) return;
    await _pushSnapshot(sessionId);
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
    // Before the dedupe and the early return: retiring a card the phone still
    // shows must not depend on the snapshot having changed shape.
    await reconcileApproval(sessionId);
    final base = await bindings.sessionById(sessionId);
    if (base == null) return;
    final snapshot = await _withStage(base);
    final encoded = jsonEncode(snapshot.toJson());
    if (_lastSnapshots[sessionId] == encoded) return;
    // Written down only once it went out. Recorded before the send, a dropped
    // `session.changed` was never repeated.
    if (await _send(FrameType.sessionChanged, payload: snapshot.toJson())) {
      _lastSnapshots[sessionId] = encoded;
    }
  }

  /// Sends the transcript growth of every subscribed session since the last
  /// poll. A no-op without the `read_transcript` capability.
  Future<void> pollTranscripts() async {
    for (final sessionId in _subscribed.toList()) {
      await pollTranscript(sessionId);
    }
  }

  /// The same, for ONE session — split out so the caller can put each on the
  /// device's serial chain by itself, rather than making the frame a user is
  /// waiting on queue behind every subscribed session's read.
  Future<void> pollTranscript(String sessionId) async {
    if (!device.capabilities.has(Capability.readTranscript)) return;
    if (!_subscribed.contains(sessionId)) return;
    // **Only a session the phone is actually reading.** A cursor exists once
    // `transcript.get` has served one; subscription cannot be that signal,
    // because the phone subscribes to every session it lists.
    final known = _transcriptCursors[sessionId];
    if (known == null) return;
    final startedAt = _uptime.elapsed;
    final notBefore = _pollNotBefore[sessionId];
    if (notBefore != null && startedAt < notBefore) return;
    // A `stat`, not a read: an append-only record that has not moved has no
    // turn this device has not been served, and re-reading one is the whole
    // cost of the poll. The backoff above still governs how often this runs;
    // this decides whether the run has anything to pay for.
    final RemoteRecordReading reading;
    try {
      reading = await bindings.readRecordState(sessionId);
    } on Object {
      return;
    }
    final revision = reading.revision;
    final unchanged = reading.activity;
    if (revision != null &&
        unchanged != null &&
        revision == _readRevisions[sessionId]) {
      // **Still owed, with the file exactly where it was.** The cursor cannot
      // have moved — nothing was appended — but what the session is *doing* is
      // read from the row and the status word, which move without it. This is
      // the same obligation `_pushActivity` is called early for below, and a
      // bare "unchanged, return" would swallow it.
      await _pushActivity(sessionId, unchanged);
      return;
    }
    final RemoteSessionRecord record;
    try {
      record = await bindings.transcriptFor(sessionId);
    } on Object {
      return;
    }
    // The revision as it was **before** the read, so a write that lands during
    // one is not remembered as served. Called only where this poll has carried
    // everything the read found: a delta the transport refused must be built
    // again, and a file remembered as served would never be read for it.
    void served() {
      if (revision == null) {
        _readRevisions.remove(sessionId);
      } else {
        _readRevisions[sessionId] = revision;
      }
    }

    final page = record.page;
    // Measured after the read, so the budget is set by what this transcript
    // actually costs rather than by a guess about its size.
    final cost = _uptime.elapsed - startedAt;
    if (cost > _pollBackoffFloor) {
      _pollNotBefore[sessionId] = _uptime.elapsed + cost * _pollBackoffFactor;
    }
    // **Before the cursor check, not after it.** A call *finishing* appends
    // nothing, so the cursor does not move and an early return would swallow
    // the one change the phone is waiting to see.
    await _pushActivity(sessionId, record.activity);
    final cursor = known;
    if (page.cursor <= cursor || cursor > page.messages.length) {
      _transcriptCursors[sessionId] = page.cursor;
      served();
      return;
    }
    // One page, never the whole delta: a session that grew by thousands of
    // messages between polls built a frame past the envelope cap, and because
    // the cursor only moves on a `true` it was rebuilt and refused for ever.
    final total = page.messages.length;
    final end = total - cursor > kRemoteTranscriptPageMax
        ? cursor + kRemoteTranscriptPageMax
        : total;
    // The cursor is what the phone has been *told*, so it moves only when the
    // delta was carried. Advancing first lost the messages outright.
    final delivered = await _send(
      FrameType.transcriptAppended,
      payload: RemoteTranscriptPage(
        sessionId: sessionId,
        // The live path matters as much as the opening one: a subagent that
        // finishes while the phone is watching arrives here.
        messages: collapseTaskNotifications(page.messages.sublist(cursor, end)),
        cursor: end,
        hasNewer: end < total,
      ).toJson(),
    );
    if (!delivered) return;
    _transcriptCursors[sessionId] = end;
    // Only once this device is level with the file. A page that left more
    // behind must not be skipped over by a `stat` saying nothing moved.
    if (end == total) served();
  }

  /// States what a session is doing, when that is not what this device was last
  /// told. Gated on [Capability.viewActivity], and called from [pollTranscript],
  /// so it follows the session the phone reads and costs no read of its own.
  Future<void> _pushActivity(
    String sessionId,
    RemoteSessionActivity activity,
  ) async {
    if (!device.capabilities.has(Capability.viewActivity)) return;
    final encoded = _activityKey(activity);
    if (_lastActivity[sessionId] == encoded) return;
    // Written down only once it went out: a frame no transport took is not news
    // the phone has, and the next poll must try again.
    if (await _send(FrameType.sessionActivity, payload: activity.toJson())) {
      _lastActivity[sessionId] = encoded;
    }
  }

  /// What is compared to decide whether the phone already knows this —
  /// everything except `observedAt`, which moves on every read by construction.
  static String _activityKey(RemoteSessionActivity activity) => jsonEncode({
    'calls': [for (final call in activity.calls) call.toJson()],
    if (activity.absence != null) 'absence': activity.absence!.wire,
  });

  /// Sends `approval.requested` with the Loop-49 evidence. Gated on the
  /// `approve` capability and deliberately not on subscription: an approval is
  /// exactly the news a phone in a pocket is paired for.
  Future<void> pushApprovalRequested(String sessionId) async {
    if (!device.capabilities.has(Capability.approve)) return;
    RemoteApprovalRequest request;
    try {
      request = await bindings.approvalEvidenceFor(sessionId);
    } on Object {
      request = RemoteApprovalRequest(sessionId: sessionId);
    }
    // Remembered only once it went out, so a card the phone never got is not
    // one this api will later try to retire.
    if (await _send(FrameType.approvalRequested, payload: request.toJson())) {
      _announcedApprovals.add(sessionId);
      _announcedAsks[sessionId] = _askOf(request);
    }
  }

  /// Announces what a waiting session asks now, when it is not what this
  /// device was last shown: one menu can replace another (folder trust, then
  /// external imports) while the session never stops waiting.
  Future<void> recheckApproval(String sessionId) async {
    if (!device.capabilities.has(Capability.approve)) return;
    if (!_subscribed.contains(sessionId) ||
        !await _awaitingApproval(sessionId)) {
      return;
    }
    final RemoteApprovalRequest request;
    try {
      request = await bindings.approvalEvidenceFor(sessionId);
    } on Object {
      return;
    }
    final ask = _askOf(request);
    if (_announcedApprovals.contains(sessionId) &&
        _announcedAsks[sessionId] == ask) {
      return;
    }
    if (await _send(FrameType.approvalRequested, payload: request.toJson())) {
      _announcedApprovals.add(sessionId);
      _announcedAsks[sessionId] = ask;
    }
  }

  /// What a request asks, and nothing that moves while it waits — the
  /// highlight, or the screen rows it is quoted with.
  static String _askOf(RemoteApprovalRequest request) => request.menu != null
      ? 'menu:${request.menu!.menuId}'
      : request.question != null
      ? 'question:${request.question!.toolUseId}'
      : 'wait:${request.waiting.wire}';

  /// Retires an approval this device was told about and is no longer waiting.
  /// Watches the host's own state rather than any one answer path, so every
  /// route lands here; nothing can say *which*, and it does not pretend to.
  Future<void> reconcileApproval(String sessionId) async {
    if (!_announcedApprovals.contains(sessionId)) return;
    if (await _awaitingApproval(sessionId)) return;
    await _sendApprovalResolved(sessionId, RemoteApprovalOutcome.elsewhere);
  }

  /// Whether the desktop would draw its own card for this session right now,
  /// read from the snapshot this api already serves so there is one source.
  Future<bool> _awaitingApproval(String sessionId) async =>
      (await bindings.sessionById(sessionId))?.attention ==
      kAttentionNeedsApproval;

  Future<void> _sendApprovalResolved(
    String sessionId,
    RemoteApprovalOutcome outcome,
  ) async {
    if (!device.capabilities.has(Capability.approve)) return;
    // Forgotten only once the phone has it: a dropped frame must leave the card
    // in the set, or the next sweep decides there is nothing to retire.
    if (await _send(
      FrameType.approvalResolved,
      payload: RemoteApprovalResolved(
        sessionId: sessionId,
        outcome: outcome,
      ).toJson(),
    )) {
      _announcedApprovals.remove(sessionId);
      _announcedAsks.remove(sessionId);
    }
  }

  /// Refuses a file this session's agent would not be able to look at. Matches
  /// the media type literally rather than by pattern, because a pattern is a
  /// thing two builds can disagree about.
  Future<void> _checkAcceptable(
    String sessionId,
    RemoteAttachmentBegin request,
  ) async {
    final support = (await bindings.sessionById(sessionId))?.attachments;
    if (support == null || !support.allowsAnything) {
      throw RemoteApiRefusal(
        ErrorCode.badRequest,
        support?.refusal ?? 'this session cannot be sent a file',
      );
    }
    if (!support.mediaTypes.contains(request.mediaType)) {
      throw RemoteApiRefusal(
        ErrorCode.badRequest,
        'this session takes ${support.mediaTypes.join(', ')}',
      );
    }
    if (request.bytes < 1 || request.bytes > support.maxBytes) {
      throw RemoteApiRefusal(
        ErrorCode.badRequest,
        'this session takes up to ${support.maxBytes} bytes',
      );
    }
  }

  String _requireString(Envelope envelope, String key) {
    final value = envelope.payload[key];
    if (value is! String || value.isEmpty) {
      throw RemoteApiRefusal(ErrorCode.badRequest, 'missing $key');
    }
    return value;
  }

  /// A trimmed string field, or null when it is absent or says nothing — an
  /// empty title is "the user left it blank", not a title.
  String? _optionalString(Envelope envelope, String key) {
    final value = envelope.payload[key];
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  Future<String> _requireSession(Envelope envelope) async {
    final sessionId = _requireString(envelope, 'sessionId');
    if (await bindings.sessionById(sessionId) == null) {
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

/// The wrapper a delegated agent's completion arrives in. Claude Code writes
/// the whole envelope into the parent transcript as an ordinary turn.
const String _taskNotificationOpen = '<task-notification>';
const String _taskNotificationClose = '</task-notification>';

/// Compiled once for the process, never per message: this runs on the poll
/// sweep. `dotAll` because a summary may wrap, and CRLF stores are ordinary.
final RegExp _taskNotificationSummary = RegExp(
  '<summary>(.*?)</summary>',
  dotAll: true,
);

/// Folds every task-notification envelope down to the one line it already
/// carries, and leaves every other message byte for byte. One in, one out —
/// `transcript.appended` pages by index — recognised by the wrapper element
/// alone, and this is where the wire's 64 KiB bound on a message is spent.
List<RemoteTranscriptMessage> collapseTaskNotifications(
  List<RemoteTranscriptMessage> messages,
) => [for (final message in messages) _collapseTaskNotification(message)];

RemoteTranscriptMessage _collapseTaskNotification(
  RemoteTranscriptMessage message,
) {
  // For the store whose lines carry \r\n, where a trailing \r would otherwise
  // hide the closing tag.
  final text = message.text.trim();
  if (!text.startsWith(_taskNotificationOpen) ||
      !text.endsWith(_taskNotificationClose)) {
    // **The live path's own bound**, applied where both wire paths already
    // meet: a bound the wire merely inherits is one a third source walks
    // around. Bytes, and the same 64 KiB the other two spend.
    final (bounded, truncated) = boundedText(text);
    return truncated
        ? RemoteTranscriptMessage(role: message.role, text: bounded)
        : message;
  }
  final summary = _taskNotificationSummary.firstMatch(text)?.group(1)?.trim();
  return RemoteTranscriptMessage(
    role: 'tool',
    // No outcome is claimed for an envelope that names none: "reported back"
    // is the only thing true of every one of them.
    text: summary == null || summary.isEmpty
        ? 'A background task reported back.'
        : summary,
  );
}
