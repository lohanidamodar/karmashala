/// Fan-out for a terminal's OSC sequences: xterm gives a `Terminal` exactly
/// **one** `onPrivateOSC` slot, so whoever took it used to silence the rest.
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
