/// What each `session.start` produced, remembered per paired device so a retry
/// cannot start a second session.
///
/// The link the phone starts a session over can drop between the launch and
/// the answer, and the only thing the phone can then do is ask again. Without
/// a ledger that second ask is indistinguishable from a second intention, and
/// the owner gets two agents in one checkout.
///
/// **Its lifetime is the device, not the connection**, and that is the whole
/// point: the companion bumps its rendezvous generation on every successful
/// dial, so the reconnect that carries the retry builds a *new*
/// [HostSessionApi]. A ledger owned by the api would be empty at exactly the
/// moment it is needed. `_DeviceRuntime` owns one and hands the same instance
/// to every api it makes for that phone.
library;

import 'dart:async';


/// How many answers one device's ledger keeps. A start is a deliberate act, so
/// this is generous for the retries it exists to absorb; the cap is only there
/// so a long-lived link cannot grow the map without bound.
const int kSessionStartLedgerCapacity = 64;

/// The longest idempotency key the host will store. A key is the phone's own
/// nonce, so anything longer is a mistake or an attempt to spend the host's
/// memory a frame at a time.
const int kMaxSessionStartKeyLength = 128;

class SessionStartLedger<T> {
  SessionStartLedger({this.capacity = kSessionStartLedgerCapacity});

  final int capacity;

  /// Insertion-ordered, which is what makes eviction "the oldest answer".
  /// Holds the *future* rather than the result so two frames racing on one key
  /// join the same launch instead of both starting one.
  final Map<String, Future<T>> _answers = {};

  /// Whether [key] already has an answer — asked before [once] so the reply
  /// can say the desktop started nothing this time.
  bool holds(String key) => _answers.containsKey(key);

  /// The answer for [key], starting one with [start] only if there is none.
  Future<T> once(
    String key,
    Future<T> Function() start,
  ) {
    final remembered = _answers[key];
    if (remembered != null) return remembered;
    final attempt = start();
    _answers[key] = attempt;
    // A start that failed created nothing, so the key must go back to being
    // free: the user's next tap is a real retry, not a request to be told
    // about the failure again.
    // A statement body, not an expression: `remove` hands back the very future
    // being listened to, and returning it from `onError` would chain the
    // derived future onto the failure it is meant to absorb.
    unawaited(
      attempt.then<void>(
        (_) {},
        onError: (Object _) {
          _answers.remove(key);
        },
      ),
    );
    while (_answers.length > capacity) {
      _answers.remove(_answers.keys.first);
    }
    return attempt;
  }
}
