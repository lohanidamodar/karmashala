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
import 'session_start_ledger.dart';

/// Seals and transmits one frame for the device this api serves. Supplied by
/// the service, which owns the channel and the transport.
///
/// Answers whether a transport actually took the frame. **False means the
/// frame is gone** — not delayed: a transport queues while it is merely
/// reconnecting, so a refusal is a link that is closed with nothing else able
/// to carry it. Everything this api remembers having told the phone is
/// therefore recorded only after a `true`; the alternative is what the owner
/// hit, a desktop convinced the phone had news it never received.
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
    SessionStartLedger? startLedger,
    // ignore: prefer_initializing_formals — named `send` for callers.
  }) : _send = send,
       _starts = startLedger ?? SessionStartLedger();

  final PairedDevice device;
  final RemoteHostBindings bindings;
  final RemoteSend _send;

  /// What this device's `session.start` frames have already produced. Supplied
  /// by the caller so it can outlive one connection — see [SessionStartLedger].
  final SessionStartLedger _starts;

  /// Where this host can be met right now, read fresh at every announcement so
  /// a relay switched on mid-session is told to the phone at once. Null (and
  /// an empty answer) simply says nothing, which is what an older host did.
  final List<Uri> Function()? relays;

  /// `host:port` of the direct LAN listener, when there is a LAN address to
  /// name — a discovery hint the phone may try, never an identity.
  final String? Function()? lanHint;

  /// Lifecycle only — never called with payload content.
  final void Function(String message)? onLog;

  final Set<String> _subscribed = <String>{};
  final Map<String, int> _transcriptCursors = <String, int>{};

  /// Sessions this device has been told are waiting on it, and not yet told
  /// are done. Kept so [reconcileApproval] can retire a card the phone is
  /// still showing — including one it was shown before a reconnect, since a
  /// runtime outlives its links.
  final Set<String> _announcedApprovals = <String>{};

  /// When each watched session may next be read, on [_uptime]'s scale.
  ///
  /// A poll costs one full transcript read, and a transcript can be very large
  /// — this repo's own longest is 53 MB, which the two-second sweep was
  /// re-reading in full every tick while a phone watched it. Everything for one
  /// device is serialised on a single chain, so that read is time the phone's
  /// own requests spend waiting.
  ///
  /// So a session that was expensive to read is read less often: the next poll
  /// waits [_pollBackoffFactor] times what the last read cost. A cheap
  /// transcript is unaffected — the wait is shorter than the sweep interval —
  /// and an expensive one settles at spending about a fifth of the time,
  /// instead of all of it.
  final Map<String, Duration> _pollNotBefore = <String, Duration>{};

  static const int _pollBackoffFactor = 4;

  /// Below this, a read is not what is starving anything, so it earns no wait.
  /// An ordinary transcript is read in single-digit milliseconds; the one that
  /// caused this is three orders of magnitude above the line.
  static const Duration _pollBackoffFloor = Duration(milliseconds: 20);

  final Stopwatch _uptime = Stopwatch()..start();
  final Map<String, String> _lastSnapshots = <String, String>{};

  Set<String> get subscribedSessions => Set.unmodifiable(_subscribed);

  /// The `host.status` greeting: the supported version range, so a companion
  /// outside it knows to update — and, since Loop 83, where this host can be
  /// reached, so a phone's saved relay set heals itself over the live link.
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
  ///
  /// The phone cannot work this out for itself: over a relay the link outlives
  /// a revoke — the host closes its own runtime, but the phone's relay socket
  /// stays up — so the next request simply goes unanswered, and silence reads
  /// exactly like a busy desktop. One frame turns that guess into a fact.
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
          // cursor to *now* — a count, for which it parsed the entire file.
          // On the owner's 115 MB store that ran far past the phone's request
          // timeout, and because a device's frames are handled on one serial
          // chain, every request queued behind it timed out too: the link was
          // up, `sessions.list` answered, and opening a session never did.
          // The desktop then logged a result frame it could no longer deliver,
          // because by then the phone had given up and redialled.
          //
          // The priming still happens, on the first poll after this — see
          // [pollTranscript], which has to read the transcript anyway. The
          // semantics are unchanged; only the request path is.
          await _result(envelope.id, const {});
          await _pushSnapshot(sessionId);
        case FrameType.sessionUnsubscribe:
          final sessionId = _requireString(envelope, 'sessionId');
          _subscribed.remove(sessionId);
          _transcriptCursors.remove(sessionId);
          _pollNotBefore.remove(sessionId);
          _lastSnapshots.remove(sessionId);
          await _result(envelope.id, const {});
        case FrameType.transcriptGet:
          final sessionId = _requireSession(envelope);
          final after = envelope.payload['after'];
          final from = after is int && after > 0 ? after : 0;
          final page = await bindings.transcriptFor(sessionId);
          // Opened at the end, and bounded. A conversation view shows the tail,
          // and a long transcript cannot be carried in one frame: this repo's
          // own longest session is 53 MB of JSONL, and sending every message of
          // it produced a result the phone never finished receiving — the
          // desktop logged "no transport could carry a result frame" three
          // times while the phone sat on a spinner. `after` still pages
          // explicitly for a caller that wants an earlier window.
          final total = page.messages.length;
          final start = from > 0
              ? (from > total ? total : from)
              : (total > kRemoteTranscriptPageMax
                    ? total - kRemoteTranscriptPageMax
                    : 0);
          // Serving history is also what marks this session as *watched*: from
          // here the poll sweep carries its growth, and until here it does not
          // read it at all. The phone asks for history only for the session it
          // has open, so this is the cheapest true signal of what is on screen
          // — and it costs no extra read, because the cursor is a by-product
          // of the page just built.
          _transcriptCursors[sessionId] = page.cursor;
          await _result(
            envelope.id,
            RemoteTranscriptPage(
              sessionId: sessionId,
              messages: collapseTaskNotifications(page.messages.sublist(start)),
              cursor: page.cursor,
              omitted: start,
              // Carried, not re-derived: this rebuilds the page to window it,
              // and dropping the reason here would have thrown away the one
              // thing that tells the phone which nothing it is looking at.
              absence: page.absence,
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
          // The host is the arbiter, and this is the reverse race: the
          // desktop (or a second phone) answered a moment ago, this answer
          // was already in flight, and applying it would type a key into
          // whatever prompt is there NOW. Refused on the same fact the
          // desktop's own card is drawn from — the session's attention — so
          // a refusal here means the desktop would show no card either.
          if (!_awaitingApproval(sessionId)) {
            throw const RemoteApiRefusal(
              // Not a new error code: `tryParse` on an older companion
              // answers null for a wire word it has never seen, and this
              // refusal is one a phone must be able to read.
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
          await bindings.registerPush(device.id, token, platform);
          await _result(envelope.id, const {});
        case FrameType.workspaceList:
          await _result(envelope.id, {
            'projects': [
              for (final project in bindings.listWorkspace()) project.toJson(),
            ],
          });
        case FrameType.sessionStart:
          // The idempotency key, first: a start that cannot be recognised on a
          // second delivery is the one request this api must never take on
          // faith. It is required rather than optional because no companion
          // ever spoke this frame without one.
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
    // Before the dedupe below, and before the early return for a session the
    // host no longer holds: retiring a card the phone is still showing must
    // not depend on the snapshot having changed shape.
    await reconcileApproval(sessionId);
    final base = bindings.sessionById(sessionId);
    if (base == null) return;
    final snapshot = await _withStage(base);
    final encoded = jsonEncode(snapshot.toJson());
    if (_lastSnapshots[sessionId] == encoded) return;
    // Written down only once it went out. Recorded before the send, a dropped
    // `session.changed` was never repeated: the next sweep found the snapshot
    // unchanged and stayed quiet, so a phone that missed one update kept the
    // stale card until it re-listed.
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

  /// The same, for ONE session.
  ///
  /// Split out so the caller can put each session on the device's serial chain
  /// by itself: a frame the user just sent then waits for a single transcript
  /// read rather than for every subscribed session's, which on a desktop
  /// watching a dozen of them is the difference between a link that answers
  /// and one that times out.
  Future<void> pollTranscript(String sessionId) async {
    if (!device.capabilities.has(Capability.readTranscript)) return;
    if (!_subscribed.contains(sessionId)) return;
    // **Only a session the phone is actually reading.** A cursor exists once
    // `transcript.get` has served one, which the phone asks for only for the
    // session it has open — so this is "what is on screen", stated by the
    // phone's own behaviour rather than guessed at.
    //
    // Subscription cannot be that signal: the phone subscribes to *every*
    // session it lists, because subscription is also what keeps the session
    // cards live. Polling on it meant a full transcript parse per listed
    // session per tick, and the parse of the largest one starved the link the
    // phone was waiting on.
    final known = _transcriptCursors[sessionId];
    if (known == null) return;
    final startedAt = _uptime.elapsed;
    final notBefore = _pollNotBefore[sessionId];
    if (notBefore != null && startedAt < notBefore) return;
    final RemoteTranscriptPage page;
    try {
      page = await bindings.transcriptFor(sessionId);
    } on Object {
      return;
    }
    // Measured after the read, so the budget is set by what this transcript
    // actually costs rather than by a guess about its size.
    final cost = _uptime.elapsed - startedAt;
    if (cost > _pollBackoffFloor) {
      _pollNotBefore[sessionId] = _uptime.elapsed + cost * _pollBackoffFactor;
    }
    final cursor = known;
    if (page.cursor <= cursor || cursor > page.messages.length) {
      _transcriptCursors[sessionId] = page.cursor;
      return;
    }
    // The cursor is what the phone has been *told*, so it moves only when the
    // delta was carried. Advancing first lost the messages outright — the next
    // poll started after them and nothing ever went back for them.
    final delivered = await _send(
      FrameType.transcriptAppended,
      payload: RemoteTranscriptPage(
        sessionId: sessionId,
        // The live path matters as much as the opening one: a subagent that
        // finishes while the phone is watching arrives here, not through
        // `transcript.get`.
        messages: collapseTaskNotifications(page.messages.sublist(cursor)),
        cursor: page.cursor,
      ).toJson(),
    );
    if (delivered) _transcriptCursors[sessionId] = page.cursor;
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
    // Remembered only once it went out, so a card the phone never got is not
    // one this api will later try to retire.
    if (await _send(FrameType.approvalRequested, payload: request.toJson())) {
      _announcedApprovals.add(sessionId);
    }
  }

  /// Retires an approval this device was told about and is no longer waiting.
  ///
  /// Watches the host's own state rather than any one answer path, which is
  /// what makes it route-independent: the desktop's card, a second paired
  /// phone and an agent that gave up all end in the same place — the session
  /// stops asking. Nothing here can say *which*, and it does not pretend to.
  ///
  /// Runs from [_pushSnapshot], so it happens on the sweep and again on every
  /// `session.subscribe` — a phone that was asleep when the answer happened
  /// is told the moment it comes back and re-subscribes.
  Future<void> reconcileApproval(String sessionId) async {
    if (!_announcedApprovals.contains(sessionId)) return;
    if (_awaitingApproval(sessionId)) return;
    await _sendApprovalResolved(sessionId, RemoteApprovalOutcome.elsewhere);
  }

  /// Whether the desktop would draw its own card for this session right now.
  ///
  /// Read from the snapshot the rest of this api already serves, so "the host
  /// says it is waiting" is one fact with one source, not two that can drift.
  bool _awaitingApproval(String sessionId) =>
      bindings.sessionById(sessionId)?.attention == kAttentionNeedsApproval;

  Future<void> _sendApprovalResolved(
    String sessionId,
    RemoteApprovalOutcome outcome,
  ) async {
    if (!device.capabilities.has(Capability.approve)) return;
    // Forgotten only once the phone has it: a dropped frame must leave the
    // card in the set, or the next sweep would decide there was nothing to
    // retire and the phone would keep it forever.
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

  String _requireString(Envelope envelope, String key) {
    final value = envelope.payload[key];
    if (value is! String || value.isEmpty) {
      throw RemoteApiRefusal(ErrorCode.badRequest, 'missing $key');
    }
    return value;
  }

  /// A trimmed string field, or null when it is absent or says nothing. An
  /// empty title is not a title, and an empty opening message is not one
  /// either — both are "the user left it blank".
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
/// the whole envelope into the parent transcript as an ordinary turn, so the
/// reader hands it on as one: this session's own store holds 199 of them, the
/// largest 7,703 characters of XML, and the phone drew each as conversation.
const String _taskNotificationOpen = '<task-notification>';
const String _taskNotificationClose = '</task-notification>';

/// Compiled once for the process, never per message: this runs on the poll
/// sweep. `dotAll` because a summary may wrap, and CRLF stores are ordinary —
/// the host runs on Windows, macOS and Linux.
final RegExp _taskNotificationSummary = RegExp(
  '<summary>(.*?)</summary>',
  dotAll: true,
);

/// Folds every task-notification envelope down to the one line it already
/// carries, and leaves every other message byte for byte.
///
/// Done here rather than in the phone's tile because the host is where the
/// whole transcript is, and because the envelope is most of what a busy
/// session sends over the link — the reason a transcript is tail-bounded at
/// [kRemoteTranscriptPageMax] at all. Measured on this session's own store:
/// 199 envelopes, 691,852 bytes, folding to 27,305; its real 300-message tail
/// page holds five of them and goes from 189,609 bytes to 128,805.
///
/// **O(page), never O(transcript)**: both callers hand it the slice they are
/// about to send — a bounded page or one poll's delta — and only a message
/// that already passed the two-string gate is matched against, so an ordinary
/// turn costs one `startsWith`.
///
/// **Recognised by the wrapper element and nothing else**: the text must open
/// AND close with it, so a person's message that merely quotes
/// `</task-notification>` is still their message, delivered whole. The
/// envelope's own `<summary>` is used verbatim — the host re-words nothing —
/// and lands as a `tool` row, which no reader can mistake for someone
/// speaking.
///
/// One in, one out. `transcript.appended` pages by index into this list, so a
/// dropped turn would shift every delta after it; and a reader whose
/// conversation quietly jumped would have no way to know that it had.
List<RemoteTranscriptMessage> collapseTaskNotifications(
  List<RemoteTranscriptMessage> messages,
) => [for (final message in messages) _collapseTaskNotification(message)];

RemoteTranscriptMessage _collapseTaskNotification(
  RemoteTranscriptMessage message,
) {
  // `trim` returns the receiver when there is nothing to take, so this costs
  // nothing for the overwhelming majority; it is here for the store whose
  // lines carry \r\n, where a trailing \r would hide the closing tag.
  final text = message.text.trim();
  if (!text.startsWith(_taskNotificationOpen) ||
      !text.endsWith(_taskNotificationClose)) {
    return message;
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
