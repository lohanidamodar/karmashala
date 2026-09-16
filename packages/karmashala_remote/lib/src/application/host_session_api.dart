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
    SessionStartLedger<RemoteSessionStarted>? startLedger,
    SessionStartLedger<RemoteSessionStarted>? resumeLedger,
    SessionStartLedger<RemoteWorkspaceProject>? projectLedger,
    SessionStartLedger<RemotePromptDelivery>? promptLedger,
    // ignore: prefer_initializing_formals — named `send` for callers.
  }) : _send = send,
       _starts = startLedger ?? SessionStartLedger<RemoteSessionStarted>(),
       _resumes = resumeLedger ?? SessionStartLedger<RemoteSessionStarted>(),
       _projects = projectLedger ?? SessionStartLedger<RemoteWorkspaceProject>(),
       _prompts = promptLedger ?? SessionStartLedger<RemotePromptDelivery>();

  final PairedDevice device;
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

  final Set<String> _subscribed = <String>{};
  final Map<String, int> _transcriptCursors = <String, int>{};

  /// Sessions this device has been told are waiting on it. Kept so
  /// [reconcileApproval] can retire a card it was shown before a reconnect.
  final Set<String> _announcedApprovals = <String>{};

  /// When each watched session may next be read, on [_uptime]'s scale. The next
  /// poll waits [_pollBackoffFactor] times what the last read cost, so an
  /// expensive transcript is read less often instead of starving the link.
  final Map<String, Duration> _pollNotBefore = <String, Duration>{};

  static const int _pollBackoffFactor = 4;

  /// Below this a read is not what is starving anything, so it earns no wait.
  static const Duration _pollBackoffFloor = Duration(milliseconds: 20);

  final Stopwatch _uptime = Stopwatch()..start();
  final Map<String, String> _lastSnapshots = <String, String>{};

  /// The activity each watched session was last **told** to have, encoded.
  /// `observedAt` is deliberately not compared: it moves on every read, and a
  /// frame per poll saying "still the same, later" is the churn this prevents.
  final Map<String, String> _lastActivity = <String, String>{};

  Set<String> get subscribedSessions => Set.unmodifiable(_subscribed);

  /// The `host.status` greeting: the supported version range, and where this
  /// host can be reached, so a phone's saved relay set heals over the live link.
  Future<void> sendHostStatus() => _send(
    FrameType.hostStatus,
    payload: RemoteHostStatus(
      versions: kSupportedVersions,
      hostName: bindings.hostName,
      relays: relays?.call() ?? const [],
      lanHint: lanHint?.call(),
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
          // **Nothing here reads the transcript.** It used to, to prime the
          // cursor to *now*; the priming happens on the first poll instead —
          // see [pollTranscript], which has to read the transcript anyway.
          await _result(envelope.id, const {});
          await _pushSnapshot(sessionId);
        case FrameType.sessionUnsubscribe:
          final sessionId = _requireString(envelope, 'sessionId');
          _subscribed.remove(sessionId);
          _transcriptCursors.remove(sessionId);
          _pollNotBefore.remove(sessionId);
          _lastSnapshots.remove(sessionId);
          _lastActivity.remove(sessionId);
          await _result(envelope.id, const {});
        case FrameType.transcriptGet:
          final sessionId = _requireSession(envelope);
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
          final sessionId = _requireSession(envelope);
          final activity = (await bindings.transcriptFor(sessionId)).activity;
          _lastActivity[sessionId] = _activityKey(activity);
          await _result(envelope.id, activity.toJson());
        case FrameType.promptSend:
          final sessionId = _requireSession(envelope);
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
          final sessionId = _requireSession(envelope);
          final request = RemoteAttachmentBegin.fromJson({
            ...envelope.payload,
            'sessionId': sessionId,
          });
          _checkAcceptable(sessionId, request);
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
          final sessionId = _requireSession(envelope);
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
          if (!_awaitingApproval(sessionId)) {
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
              for (final project in bindings.listWorkspace()) project.toJson(),
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
              for (final project in bindings.listProjects())
                project.toJson()..remove('checkouts'),
            ],
          });
        case FrameType.projectAdd:
          final key = _requireString(envelope, 'requestId');
          if (key.length > kMaxSessionStartKeyLength) {
            throw const RemoteApiRefusal(ErrorCode.badRequest, 'requestId is too long');
          }
          final name = _requireString(envelope, 'name');
          final path = _requireString(envelope, 'path');
          final replayed = _projects.holds(key);
          final project = await _projects.once(key, () => bindings.addProject(name, path));
          await _result(envelope.id, {...project.toJson(), if (replayed) 'replayed': true});
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
            throw const RemoteApiRefusal(ErrorCode.badRequest, 'requestId is too long');
          }
          final sessionId = _requireString(envelope, 'sessionId');
          final replayed = _resumes.holds(key);
          final resumed = await _resumes.once(key, () => bindings.resumeSession(sessionId));
          await _result(envelope.id, {...resumed.toJson(), if (replayed) 'replayed': true});
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
    final base = bindings.sessionById(sessionId);
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
    final RemoteSessionRecord record;
    try {
      record = await bindings.transcriptFor(sessionId);
    } on Object {
      return;
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
        messages: collapseTaskNotifications(
          page.messages.sublist(cursor, end),
        ),
        cursor: end,
        hasNewer: end < total,
      ).toJson(),
    );
    if (delivered) _transcriptCursors[sessionId] = end;
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
    }
  }

  /// Retires an approval this device was told about and is no longer waiting.
  /// Watches the host's own state rather than any one answer path, so every
  /// route lands here; nothing can say *which*, and it does not pretend to.
  Future<void> reconcileApproval(String sessionId) async {
    if (!_announcedApprovals.contains(sessionId)) return;
    if (_awaitingApproval(sessionId)) return;
    await _sendApprovalResolved(sessionId, RemoteApprovalOutcome.elsewhere);
  }

  /// Whether the desktop would draw its own card for this session right now,
  /// read from the snapshot this api already serves so there is one source.
  bool _awaitingApproval(String sessionId) =>
      bindings.sessionById(sessionId)?.attention == kAttentionNeedsApproval;

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
    }
  }

  /// Refuses a file this session's agent would not be able to look at. Matches
  /// the media type literally rather than by pattern, because a pattern is a
  /// thing two builds can disagree about.
  void _checkAcceptable(String sessionId, RemoteAttachmentBegin request) {
    final support = bindings.sessionById(sessionId)?.attachments;
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
