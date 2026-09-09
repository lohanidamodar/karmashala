/// Fan-out for a terminal's operating-system commands.
///
/// xterm gives a `Terminal` exactly **one** `onPrivateOSC` slot, and more than
/// one part of the app now needs the stream: the OSC 133 command recorder,
/// which exists only when shell integration is on, and the OSC 7 working
/// directory, which has to work whether it is or not. Whoever grabbed the slot
/// last used to silence the other.
///
/// So the slot belongs to the *pane*, which installs [dispatch] once and keeps
/// it for its whole life; everything else registers here. Chaining callbacks at
/// the call site would have worked for two listeners and quietly broken at
/// three.
///
/// Pure Dart on purpose — no Flutter, no xterm — so the fan-out is testable
/// without a terminal.
///
/// ## "Private" means what the parser did not already claim
///
/// A sequence reaches here only when the vendored parser falls through to its
/// `unknownOSC` handler, and a `case` on the OSC number never does. **777 is
/// one of those numbers:** a `notify` payload goes to
/// `Terminal.showNotification` and every other shape of 777 is dropped, so
/// neither reaches this router. This app sets no `onNotification` either,
/// which means a 777 is currently parsed and thrown away.
///
/// Written down because a backlog item proposed reading typed agent events
/// (`warp://cli-agent`) out of the PTY on the assumption that they would arrive
/// here. `osc_777_notify_test.dart` measures it instead, and records what the
/// sequence actually is and who emits it.
library;

/// What xterm hands to `onPrivateOSC`: the OSC number, and everything after it
/// split on `;`.
typedef OscListener = void Function(String code, List<String> args);

/// Delivers every OSC to every registered [OscListener].
class OscRouter {
  final List<OscListener> _listeners = [];

  /// Starts delivering to [listener]. Registering twice delivers twice.
  void add(OscListener listener) => _listeners.add(listener);

  void remove(OscListener listener) => _listeners.remove(listener);

  /// Install as `terminal.onPrivateOSC`.
  void dispatch(String code, List<String> args) {
    // Over a copy: a listener may remove itself from inside this call, and
    // mutating the live list mid-iteration would skip the one after it — the
    // same rule `CommandBlockTracker._complete` follows for its waiters.
    for (final listener in List.of(_listeners)) {
      listener(code, args);
    }
  }
}
