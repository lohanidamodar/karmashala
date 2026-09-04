import 'agent_session_key.dart';

/// A session the watcher keeps an eye on, with everything needed to talk about
/// it (a label) and to jump to it (the workspace id it opens under).
class WatchedSession {
  const WatchedSession({
    required this.key,
    required this.label,
    required this.openId,
    required this.imported,
    this.paneId,
    this.stateFilePath,
  });

  final AgentSessionKey key;

  /// What to call this session in a toast or a tray menu item.
  final String label;

  /// The workspace row id to select when the user asks to open this — an
  /// imported session id when [imported], otherwise a native session id.
  final String openId;

  final bool imported;

  /// The live pane this native session occupies, when it has one.
  ///
  /// Carried from the loader's already-read session row so a status cycle does
  /// not query that same row again merely to recover its pane id. Imported
  /// sessions never have an in-app pane.
  final String? paneId;

  /// The agent's transcript file, when one is known. `null` for native
  /// sessions, whose status can only come from hooks.
  final String? stateFilePath;

  @override
  bool operator ==(Object other) =>
      other is WatchedSession &&
      other.key == key &&
      other.label == label &&
      other.openId == openId &&
      other.imported == imported &&
      other.paneId == paneId &&
      other.stateFilePath == stateFilePath;

  @override
  int get hashCode =>
      Object.hash(key, label, openId, imported, paneId, stateFilePath);

  @override
  String toString() => 'WatchedSession($key, $label)';
}
