part of 'remote_companion_gateway.dart';

// Every way a request can fail, in a sentence a user can read — and the count
// of unanswered requests that decides the link is no longer one.

/// The two refusals every unreachable-or-unpaired path shares; kept identical
/// to the fake gateway's copy so the UI reads one voice.
const String _kNotPaired = 'This phone is not paired with a host.';
const String _kUnreachable =
    'The host is unreachable right now, so nothing was sent.';

/// A request that went out and was not answered in time.
///
/// Deliberately *not* [_kUnreachable]. The owner's report was exactly this
/// sentence being wrong: "this did not work host is unreachable now. which is
/// not the case host is here this session is running on the host" — said while
/// the status bar beside it read "Working · running here". Both halves of that
/// sentence are false for a timeout: the host is demonstrably reachable, since
/// the link is carrying frames, and the request *was* sent. Only the answer is
/// missing, and the honest reason is usually that the desktop is busy.
///
/// It no longer says *why*, though. "The link is up, so it is busy with
/// something else" is a claim the phone cannot support from one unanswered
/// request — and after a revoke it is flatly wrong: the relay socket does
/// outlive the pairing, so the link looks up while the host will never answer
/// again. That case is now told outright ([_kRevoked]); everything left here is
/// genuinely unknown, and reads that way.
const String _kUnanswered =
    'The desktop did not answer in time. The request was sent, so it may still '
    'be working on it.';

/// The host revoked this pairing and said so on the way out.
const String _kRevoked =
    'This pairing was revoked on the desktop. Pair again to reconnect.';

/// How many of those the link is given before the phone stops calling it
/// connected.
///
/// ONE is a busy desktop, and must cost nothing: the host serialises every
/// frame for one device on a single chain (`_DeviceRuntime._chain`, so that
/// `Envelope.seq` and the sealed sequence agree), so one slow binding call
/// holds up whatever is behind it. Re-dialling would not help — the same
/// runtime, with the same busy chain, is still there afterwards.
///
/// TWO in a row, with nothing answered in between, is a different animal:
/// the phone is putting frames into a link that brings nothing back. That is
/// where the owner's phone sat, showing the last list the desktop ever sent
/// and calling itself connected, for as long as the app was left open.
const int _kUnansweredBeforeDoubt = 2;

const String _kHostSilentTrouble =
    'Your desktop is keeping this connection open but not answering it. '
    'What you can see here is what it last sent.';

extension _GatewayRefusals on RemoteCompanionGateway {
  CompanionClient _requireClient() {
    if (_revoked) throw const GatewayException(_kRevoked);
    if (_record == null) throw const GatewayException(_kNotPaired);
    final client = _client;
    if (client == null ||
        !client.isConnected ||
        _link.value != CompanionLinkState.connected) {
      // Same reading as _mapRefusals: the link is not what it claims, so the
      // loop must re-dial. Without this the phone parks on a relay socket the
      // host has left — alone at the rendezvous, still reported "connected" —
      // and never dials again.
      _declareDead();
      throw GatewayException(_unusableLink);
    }
    return client;
  }

  /// Runs one request, rewriting every way it can fail into a sentence.
  Future<T> _mapRefusals<T>(Future<T> Function() action) async {
    try {
      final answer = await action();
      // Whatever went unanswered before it, this link is demonstrably
      // carrying traffic both ways.
      _unanswered = 0;
      return answer;
    } on RemoteApiException catch (error) {
      if (error.code == null) {
        // A request already in flight when the revoke arrived. The frame and
        // the request race by nature — the phone asks, the host revokes, the
        // answer never comes — so what matters is which is known by the time
        // the failure is described, not which happened first.
        if (_revoked) throw const GatewayException(_kRevoked);
        _noteUnanswered();
        throw const GatewayException(_kUnanswered);
      }
      // A refusal is an ANSWER: the desktop read the frame and said no, which
      // is the strongest possible evidence the link works.
      _unanswered = 0;
      throw GatewayException(_sentenceFor(error));
    } on TransportException {
      _declareDead();
      throw const GatewayException(_kUnreachable);
    } on StateError {
      // "Not connected" — the link went away under the request. Which sentence
      // that deserves depends on why it went away.
      throw GatewayException(_unusableLink);
    }
  }

  void _noteUnanswered() {
    // A promotion is deciding whether a second link carries. A request that
    // goes unanswered while it does is news about that candidate, not about
    // the link this phone is holding — and the promotion's own rollback is
    // what answers it. Counting it here would declare the working link dead
    // for the sake of one that never became a link at all.
    if (_promoting) return;
    _unanswered++;
    if (_unanswered < _kUnansweredBeforeDoubt) {
      onLog?.call('a request went unanswered; the link itself still holds');
      return;
    }
    onLog?.call('nothing on this link is being answered; it is not a link');
    _noteTrouble(_kHostSilentTrouble);
    // Said here rather than waiting for the loop to say it: the knowledge is
    // gained now, and a screen that keeps claiming "connected" until a teardown
    // gets round to it is the whole complaint.
    if (_link.value == CompanionLinkState.connected) {
      _link.value = CompanionLinkState.connecting;
    }
    // And dial again. A busy desktop is unhelped by it and loses nothing; a
    // link whose channel the desktop can no longer open — a phone back on a
    // generation it had already used — is fixed by exactly this, because the
    // next dial lands on a fresh generation with a fresh channel.
    _unanswered = 0;
    _declareDead();
  }

  /// What a link that carries frames one way and brings nothing back reads
  /// like. Never "connected", and never "check your connection": the socket is
  /// up, the relay is fine, and the list on screen is real — it is simply the
  /// last thing the desktop sent rather than anything it is saying now.
  /// The sentence for a link that cannot be used right now.
  ///
  /// "Unreachable" is only true when the phone cannot get to the desktop at
  /// all. When the link was torn down *because* the desktop stopped answering,
  /// that word contradicts the banner directly above it — which says the
  /// desktop is holding the connection open and not answering — and the owner
  /// saw both sentences on one screen at once.
  String get _unusableLink =>
      _trouble.value == _kHostSilentTrouble ? _kUnanswered : _kUnreachable;

  /// The protocol-error → user-sentence table.
  String _sentenceFor(RemoteApiException error) => switch (error.code!) {
    ErrorCode.notPermitted =>
      'The desktop did not grant this phone permission to do that. '
          'Re-pair with more access to use it.',
    ErrorCode.unsupportedVersion =>
      'This app and the desktop speak different protocol versions. '
          'Update whichever is older and pair again.',
    ErrorCode.notFound => 'The desktop no longer has that session.',
    ErrorCode.badRequest => 'The desktop refused: ${error.message}.',
    ErrorCode.unknownType =>
      'The desktop did not understand the request — one of the two apps '
          'is out of date.',
    ErrorCode.internal =>
      'Something went wrong on the desktop while handling that request.',
  };

  GatewayException _asGatewayError(Object error) =>
      error is GatewayException ? error : const GatewayException(_kUnreachable);
}
