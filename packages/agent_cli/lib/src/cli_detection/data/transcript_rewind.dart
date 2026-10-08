import '../../agents/adapter/agent_rewind.dart';

/// The role of the row a rewind leaves where it cut the conversation: the
/// turns before it, back to the message rewound to, are kept but rewound.
const String kTranscriptRewindRole = 'rewound';

/// What a rewind row says: how many turns it undid, and what it put back.
final class RewindMarker {
  const RewindMarker({required this.turns, required this.mode});

  final int turns;
  final RewindMode mode;

  static final _pattern = RegExp(r'^Rewound (\d+) turns? · (.+)$');

  /// The row's text, which [parse] reads back.
  String get text =>
      'Rewound $turns turn${turns == 1 ? '' : 's'} · ${mode.label}';

  static RewindMarker? parse(String text) {
    final match = _pattern.firstMatch(text.trim());
    if (match == null) return null;
    final turns = int.parse(match.group(1)!);
    for (final mode in RewindMode.values) {
      if (mode.label == match.group(2)) {
        return RewindMarker(turns: turns, mode: mode);
      }
    }
    return null;
  }
}

/// Which of [count] rows a rewind undid. Each rewind row folds the [RewindMarker.turns]
/// turns before it that no earlier rewind folded, and everything from the
/// first of them up to itself; the rewind rows themselves are not folded.
List<bool> rewoundRows(
  int count, {
  required String Function(int index) roleAt,
  required String Function(int index) textAt,
  required bool Function(int index) opensTurn,
}) {
  final rewound = List<bool>.filled(count, false);
  for (var m = 0; m < count; m++) {
    if (roleAt(m) != kTranscriptRewindRole) continue;
    final marker = RewindMarker.parse(textAt(m));
    if (marker == null || marker.turns <= 0) continue;
    var left = marker.turns;
    var start = m;
    for (var i = m - 1; i >= 0 && left > 0; i--) {
      if (roleAt(i) == kTranscriptRewindRole) continue;
      if (!rewound[i] && opensTurn(i)) {
        left--;
        start = i;
      }
    }
    for (var i = start; i < m; i++) {
      if (roleAt(i) != kTranscriptRewindRole) rewound[i] = true;
    }
  }
  return rewound;
}
