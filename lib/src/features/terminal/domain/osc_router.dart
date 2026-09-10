/// Fan-out for a terminal's operating-system commands.
///
/// xterm gives a `Terminal` exactly **one** `onPrivateOSC` slot, and two things
/// need the stream — the OSC 133 recorder and the OSC 7 directory — so whoever
/// grabbed it last used to silence the other. The slot now belongs to the pane.
///
/// A sequence reaches here only through the parser's `unknownOSC` fallthrough,
/// which a `case` on the number never takes: **777 is one of those numbers**,
/// so no `notify` payload ever arrives — see `osc_777_notify_test.dart`.
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
    // mutating the live list mid-iteration would skip the one after it.
    for (final listener in List.of(_listeners)) {
      listener(code, args);
    }
  }
}
