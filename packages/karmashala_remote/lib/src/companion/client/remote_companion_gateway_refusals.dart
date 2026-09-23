part of 'remote_companion_gateway.dart';

// Every way a request can fail, in a sentence a user can read — and the count
// of unanswered requests that decides the link is no longer one.

/// The two refusals every unreachable-or-unpaired path shares; kept identical
/// to the fake gateway's copy so the UI reads one voice.
const String _kNotPaired = 'This phone is not paired with a host.';
const String _kUnreachable =
    'The host is unreachable right now, so nothing was sent.';

/// A request that went out and was not answered in time. Deliberately *not*
/// [_kUnreachable]: the host is demonstrably reachable — the link is carrying
/// frames — and the request was sent; only the answer is missing. It no longer
/// says why, because "busy" is a claim one unanswered request cannot support,
/// and is flatly wrong after a revoke ([_kRevoked]).
const String _kUnanswered =
    'The desktop did not answer in time. The request was sent, so it may still '
    'be working on it.';

/// The host revoked this pairing and said so on the way out.
const String _kRevoked =
    'This pairing was revoked on the desktop. Pair again to reconnect.';

/// How many of those the link is given before the phone stops calling it
/// connected. ONE is a busy desktop and must cost nothing: the host serialises
/// every frame for one device on a single chain, so a slow binding call holds
/// up what is behind it and a re-dial reaches the same chain. TWO in a row,
/// with nothing answered between, is a link that brings nothing back.
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
    // A request that goes unanswered while a promotion is deciding is news
    // about that candidate, not about the link this phone is holding; the
    // promotion's own rollback is what answers it.
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

  /// The sentence for a link that cannot be used right now. Never "connected",
  /// and never "unreachable" when the link was torn down *because* the desktop
  /// stopped answering: that word contradicts the banner directly above it.
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
    ErrorCode.streamStalled =>
      'The desktop paused its updates while this phone caught up.',
    ErrorCode.outOfOrder =>
      'That arrived out of order, so the desktop did not act on it. '
          'Try again.',
  };

  GatewayException _asGatewayError(Object error) =>
      error is GatewayException ? error : const GatewayException(_kUnreachable);
}
