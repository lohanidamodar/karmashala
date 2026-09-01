/// The `[Image #6]` an agent CLI prints into a pane, and what it names.
///
/// The owner's request: *"image link inside terminal still not wired, i should
/// be able to ctrl click on the image `[Image #6]` and preview the image in
/// dialog"*.
///
/// ## What the number is, and what it is not
///
/// It is **not** a position in the media panel, and this was checked against
/// the owner's own transcripts under `~/.claude/projects` before anything was
/// built, because getting it wrong opens the wrong picture — which is worse
/// than opening none. Three findings, all off real files:
///
/// * The CLI counts **pastes**; [SessionMediaItem.sequence] counts everything
///   the scan finds. In `…/proc-nepal/cbc07274-….jsonl` the picture printed as
///   `[Image #6]` is the scanner's 94th item, because 87 `Read` results came
///   between. Position is therefore the wrong key by a wide margin.
/// * The counter is not even the *paste* ordinal. `…/appwrite-ai-workdir/
///   7977d17c-….jsonl` opens at `[Image #4]`: the session was resumed and the
///   counter carried on from a process whose transcript is elsewhere.
/// * The counter belongs to a CLI **process**, so it restarts.
///   `cbc07274-….jsonl` runs `#1`…`#6` and then begins again at `#1`, and
///   `7977d17c-….jsonl` holds two different pictures both called `#6`.
///
/// What *is* exact is the CLI's own record: every line that carries a pasted
/// picture also carries `imagePasteIds`, whose values are precisely the numbers
/// printed on screen. That held for all 28 paste lines across the ten
/// transcripts on this machine, spanning CLI versions 2.1.217 to 2.1.252. So
/// the id is read out of the transcript rather than inferred — see
/// `SessionMediaStore._claudeBlocks` — and a picture whose line does not carry
/// one is simply not addressable, which the pane says in words.
///
/// ## `[Audio #N]` is deliberately not recognised
///
/// Claude Code's bundle carries the parser `Image #\d+|Audio #\d+`, so it
/// prints audio references in the same shape. Karmashala offers nothing for
/// them: [kMediaTypeExtensions] is images only, the scan never extracts a sound
/// file, and the panel has no player. A link that could only ever refuse is
/// worse than no link, so an audio reference is left as plain text. If sound
/// ever lands in the media store this is the one place that has to change.
///
/// Pure text: no filesystem, no providers. Finding the reference is one regex
/// over one line, and it only runs while the link modifier is held.
library;

import 'session_media_item.dart';

/// The exact text the CLI writes. Case-sensitive and fully bracketed on
/// purpose: `Image #6` in prose is somebody talking about a picture, and a link
/// under it would be a link to whatever the number happened to hit.
///
/// The digits are bounded because the id is a small counter and an unbounded
/// run would only ever be an overflow waiting to happen.
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

  /// How the reference is written for the user — the same text it matched, so
  /// a hint never renames what is on screen.
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

/// The reference covering character [index] of [text], or null when there is
/// none there — the same "what is under the pointer" question `linkAt` answers
/// for paths.
SessionImageReference? imageReferenceAt(String text, int index) {
  for (final reference in imageReferencesIn(text)) {
    if (index >= reference.start && index < reference.end) return reference;
  }
  return null;
}
