import 'agent_session_key.dart';
import 'attention_json.dart';

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

  /// The live pane this native session occupies, when it has one. Carried from
  /// the loader's row so a cycle need not re-query it; imported have none.
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

  /// The wire shape. [stateFilePath] and [paneId] are the watcher's own
  /// bookkeeping, spelled for the server's machine: they travel, but a client
  /// reads a file by neither.
  Map<String, Object?> toJson() => {
    'key': key.toJson(),
    'label': label,
    'openId': openId,
    if (imported) 'imported': true,
    'paneId': ?paneId,
    'stateFilePath': ?stateFilePath,
  };

  static WatchedSession fromJson(Object? json) {
    final map = attentionObject(json, 'watched session');
    return WatchedSession(
      key: AgentSessionKey.fromJson(map['key']),
      label: attentionString(map, 'label'),
      openId: attentionString(map, 'openId'),
      imported: map['imported'] == true,
      paneId: map['paneId'] as String?,
      stateFilePath: map['stateFilePath'] as String?,
    );
  }
}
