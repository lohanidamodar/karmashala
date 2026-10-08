import 'dart:convert';

/// The app-metadata key holding each session's pending conversation cut.
const String kRewindCutsKey = 'rewind_cuts.v1';

/// **A rewind's conversation cut, kept until a message lands on it.** Claude
/// Code holds a `--resume-session-at` cut only once something is sent after
/// it; a resume before then (a restart, the server's own) loads the whole
/// conversation again. So the cut is applied to every load of the session
/// until its first prompt is sent, and survives a server restart.
class RewindCuts {
  RewindCuts({this.read, this.write});

  final String? Function()? read;
  final void Function(String value)? write;

  Map<String, String>? _cuts;

  Map<String, String> get _all {
    final loaded = _cuts;
    if (loaded != null) return loaded;
    final cuts = <String, String>{};
    try {
      final decoded = jsonDecode(read?.call() ?? '{}');
      if (decoded is Map) {
        for (final MapEntry(:key, :value) in decoded.entries) {
          if (key is String && value is String) cuts[key] = value;
        }
      }
    } on FormatException {
      // A record that cannot be read holds no cut.
    }
    return _cuts = cuts;
  }

  /// The entry [sessionId]'s next load keeps its conversation up to.
  String? cutOf(String sessionId) => _all[sessionId];

  void cut(String sessionId, String entry) {
    _all[sessionId] = entry;
    _save();
  }

  /// A message was sent after the cut, or the session started over: it holds.
  void taken(String sessionId) {
    if (_all.remove(sessionId) != null) _save();
  }

  void _save() => write?.call(jsonEncode(_all));
}
