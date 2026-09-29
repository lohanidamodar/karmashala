/// The `[Image #6]` an agent CLI prints into a pane: a per-process paste
/// counter read out of `imagePasteIds`, never [SessionMediaItem.sequence] and
/// never unique. `[Audio #N]` is deliberately not matched.
library;

import 'package:agent_cli/read.dart' show SessionMediaItem;

/// The exact text the CLI writes. Case-sensitive and fully bracketed: `Image #6`
/// in prose is somebody talking about a picture, not a link.
final RegExp _reference = RegExp(r'\[Image #(\d{1,6})\]');

/// One `[Image #N]` found in a line, with where it sits in that line.
class SessionImageReference {
  const SessionImageReference({
    required this.pasteId,
    required this.start,
    required this.end,
  });

  /// The number the CLI printed — its `imagePasteIds` value, not an ordinal.
  final int pasteId;

  /// Character index of the opening `[`, and one past the closing `]`.
  final int start;
  final int end;

  /// How the reference is written for the user — the same text it matched.
  String get label => '[Image #$pasteId]';

  @override
  String toString() => 'SessionImageReference($label, $start..$end)';

  @override
  bool operator ==(Object other) =>
      other is SessionImageReference &&
      other.pasteId == pasteId &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(pasteId, start, end);
}

/// Every reference in [text], in reading order.
List<SessionImageReference> imageReferencesIn(String text) {
  if (!text.contains('[Image #')) return const [];
  final found = <SessionImageReference>[];
  for (final match in _reference.allMatches(text)) {
    final id = int.tryParse(match[1]!);
    if (id == null) continue;
    found.add(
      SessionImageReference(pasteId: id, start: match.start, end: match.end),
    );
  }
  return found;
}

/// The reference covering character [index] of [text], or null — the same
/// "what is under the pointer" question `linkAt` answers for paths.
SessionImageReference? imageReferenceAt(String text, int index) {
  for (final reference in imageReferencesIn(text)) {
    if (index >= reference.start && index < reference.end) return reference;
  }
  return null;
}
