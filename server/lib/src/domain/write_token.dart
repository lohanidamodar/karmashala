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

/// One writer, many readers; observers never claim. A refusal names the holder
/// and the age of the claim, which "someone else has it" alone cannot be acted on.
class WriteToken {
  WriteClaim? _holder;
  DateTime? _lastActiveAt;

  /// How long a holder must have typed nothing before another client's
  /// keystroke takes the token from it (slice 5e).
  static const idleBeforeTakeover = Duration(seconds: 3);

  /// When the holder last typed, or claimed.
  DateTime? get lastActiveAt => _lastActiveAt;

  /// The holder typed.
  void touch(DateTime now) => _lastActiveAt = now;

  /// Whether a keystroke from someone else may take the token now: nobody
  /// holds it, or its holder has been idle past [idleBeforeTakeover].
  bool yieldsTo(String clientId, DateTime now) {
    final current = _holder;
    if (current == null || current.clientId == clientId) return true;
    final last = _lastActiveAt ?? current.claimedAt;
    return now.difference(last) > idleBeforeTakeover;
  }

  WriteClaim? get holder => _holder;
  bool get isHeld => _holder != null;
  bool isHeldBy(String clientId) => _holder?.clientId == clientId;

  /// Claims for [clientId], or refuses. A re-claim by the holder keeps the
  /// original age: it says how long they have been driving, not when they asked.
  ClaimRefusal? claim(String clientId, DateTime now) {
    final current = _holder;
    if (current == null) {
      _holder = WriteClaim(clientId: clientId, claimedAt: now);
      _lastActiveAt = now;
      return null;
    }
    if (current.clientId == clientId) return null;
    return ClaimRefusal.heldBy(current, now);
  }

  /// Only the holder can release; releasing one never held is not an error.
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
      _lastActiveAt = now;
      return null;
    }
    if (current.clientId != from) {
      return ClaimRefusal.heldBy(current, now);
    }
    _holder = WriteClaim(clientId: to, claimedAt: now);
    _lastActiveAt = now;
    return null;
  }
}
