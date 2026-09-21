import 'checkpoint.dart';

/// What a before-turn checkpoint admits when nothing held the tool it was
/// taken for until it existed.
const String kUnverifiedBeforeNote = 'may already include its first edit';

/// The longest headline a title carries; the rest of a prompt is not a title.
const int kCheckpointHeadlineLimit = 72;

/// A row's title: what its turn was asked to do and which side of it, or why
/// it was taken. The panel and the MCP tools say the same words.
///
/// An automatic before-turn checkpoint carries a label only when the recorder
/// could not verify it predates the turn's first edit, so any label there —
/// whatever its wording, older rows included — keeps that warning in the title.
String checkpointTitle(Checkpoint checkpoint) {
  final turn = checkpoint.turn;
  final headline = checkpointHeadline(checkpoint);
  final title = switch (checkpoint.reason) {
    CheckpointReason.turnStart when headline != null => 'Before: $headline',
    CheckpointReason.turn when headline != null => 'After: $headline',
    CheckpointReason.turnStart when turn != null => 'Before turn $turn',
    CheckpointReason.turn when turn != null => 'After turn $turn',
    CheckpointReason.turnStart => 'Before turn #${checkpoint.sequence}',
    CheckpointReason.turn => 'Turn #${checkpoint.sequence}',
    CheckpointReason.safety =>
      checkpoint.label ?? 'Before restore #${checkpoint.sequence}',
    CheckpointReason.manual =>
      checkpoint.label ?? 'Checkpoint #${checkpoint.sequence}',
  };
  return isUnverifiedBefore(checkpoint)
      ? '$title — $kUnverifiedBeforeNote'
      : title;
}

/// Whether [checkpoint] is a before-turn snapshot the recorder marked as
/// possibly taken after the turn's first edit.
bool isUnverifiedBefore(Checkpoint checkpoint) =>
    checkpoint.reason == CheckpointReason.turnStart && checkpoint.label != null;

/// The words an automatic checkpoint is titled by, or null for none: its
/// turn's prompt, else — after a turn only — the files it changed. A
/// before-turn row's files are what changed *before* the turn, so naming them
/// would misdescribe it.
String? checkpointHeadline(Checkpoint checkpoint) {
  final reason = checkpoint.reason;
  if (reason != CheckpointReason.turnStart && reason != CheckpointReason.turn) {
    return null;
  }
  return promptHeadline(checkpoint.prompt) ??
      (reason == CheckpointReason.turn ? _filesHeadline(checkpoint) : null);
}

/// One short line of [prompt]: its first paragraph outside any code fence,
/// joined and clipped, with runs of 40 unbroken characters — a key, a token, a
/// blob — replaced by an ellipsis. A pasted wall is not a title, and a secret
/// in it should not become one.
String? promptHeadline(String? prompt) {
  if (prompt == null) return null;
  final lines = <String>[];
  var fenced = false;
  for (final raw in prompt.split('\n')) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('```')) {
      if (lines.isNotEmpty) break;
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    final line = trimmed
        .replaceFirst(RegExp(r'^(?:[#>*\-]+\s*)+'), '')
        .replaceAll(RegExp(r'\S{40,}'), '…')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(line)) {
      if (lines.isNotEmpty) break;
      continue;
    }
    lines.add(line);
    if (lines.join(' ').length > kCheckpointHeadlineLimit) break;
  }
  return lines.isEmpty ? null : _clip(lines.join(' '));
}

String? _filesHeadline(Checkpoint checkpoint) {
  final names = [for (final f in checkpoint.files) f.path.split('/').last];
  return switch (names.length) {
    0 => null,
    1 => _clip(names[0]),
    2 => _clip('${names[0]}, ${names[1]}'),
    _ => '${_clip('${names[0]}, ${names[1]}')} and ${names.length - 2} more',
  };
}

String _clip(String text) {
  if (text.length <= kCheckpointHeadlineLimit) return text;
  final cut = text.substring(0, kCheckpointHeadlineLimit - 1);
  final space = cut.lastIndexOf(' ');
  return '${space > kCheckpointHeadlineLimit ~/ 2 ? cut.substring(0, space) : cut}…';
}
