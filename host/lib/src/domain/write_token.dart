import 'age.dart';

/// Who holds a session's write-and-resize right, and since when.
class WriteClaim {
  const WriteClaim({required this.clientId, required this.claimedAt});

  final String clientId;
  final DateTime claimedAt;

  String describeAt(DateTime now) =>
      '$clientId (claimed ${describeAge(now.difference(claimedAt))})';
}

/// Why a write was refused, worded so the client can say it out loud.
class ClaimRefusal {
  const ClaimRefusal.heldBy(WriteClaim this.holder, this.observedAt);

  /// Refused because nobody is driving: an observer must claim before typing.
  const ClaimRefusal.unclaimed(this.observedAt) : holder = null;

  final WriteClaim? holder;
  final DateTime observedAt;

  String get message {
    final current = holder;
    if (current == null) {
      return 'nobody holds the write token for this session; claim it first';
    }
    return 'write token held by ${current.describeAt(observedAt)}';
  }
}

/// One writer, many readers.
///
/// Observers never claim: a second app window watching a session must not be
/// able to type into it by accident. A refusal names the holder and the age of
/// the claim, because "someone else has it" is not something a user can act on.
class WriteToken {
  WriteClaim? _holder;

  WriteClaim? get holder => _holder;
  bool get isHeld => _holder != null;
  bool isHeldBy(String clientId) => _holder?.clientId == clientId;

  /// Claims for [clientId], or refuses. Re-claiming by the current holder
  /// succeeds and does not reset the claim's age — the age answers "how long
  /// has this client been driving", not "when did it last ask".
  ClaimRefusal? claim(String clientId, DateTime now) {
    final current = _holder;
    if (current == null) {
      _holder = WriteClaim(clientId: clientId, claimedAt: now);
      return null;
    }
    if (current.clientId == clientId) return null;
    return ClaimRefusal.heldBy(current, now);
  }

  /// Only the holder can release. A client releasing a token it never had is
  /// not an error — it is the ordinary shape of a disconnect cleanup.
  bool release(String clientId) {
    if (_holder?.clientId != clientId) return false;
    _holder = null;
    return true;
  }

  /// A disconnect frees the token: a client that is gone cannot hand it over.
  void releaseIfHeldBy(String clientId) => release(clientId);

  /// Deliberate transfer, so a user can move control between panes without a
  /// gap in which a third client can take it.
  ClaimRefusal? handOver(String from, String to, DateTime now) {
    final current = _holder;
    if (current == null) {
      _holder = WriteClaim(clientId: to, claimedAt: now);
      return null;
    }
    if (current.clientId != from) {
      return ClaimRefusal.heldBy(current, now);
    }
    _holder = WriteClaim(clientId: to, claimedAt: now);
    return null;
  }
}
