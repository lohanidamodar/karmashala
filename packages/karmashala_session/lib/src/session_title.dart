/// Who names a session: a person, or — until one does — the machine.
library;

/// The titles Karmashala writes itself. Each means "nobody has named this
/// yet", so the agent's own name for the conversation may replace it.
const Set<String> kAppGeneratedSessionTitles = {'New session', 'Session'};

/// What a new row is called when nothing names it.
const String kUnnamedSessionTitle = 'Session';

/// Whether [title] leaves the naming to the machine: blank, or one of
/// Karmashala's own placeholders.
bool isPlaceholderSessionTitle(String title) {
  final trimmed = title.trim();
  return trimmed.isEmpty || kAppGeneratedSessionTitles.contains(trimmed);
}

/// The title a new session's row is written with, and whether it is a
/// person's. [typed] says a person gave [title] — a New-session dialog, a
/// phone's start — rather than a program (an automation's name, a spawn):
/// then it is theirs unless it is blank or a placeholder, and no CLI or
/// agent title ever replaces it. Blank becomes [kUnnamedSessionTitle].
({String title, bool byUser}) newSessionTitle(
  String title, {
  required bool typed,
}) {
  final trimmed = title.trim();
  return (
    title: trimmed.isEmpty ? kUnnamedSessionTitle : trimmed,
    byUser: typed && !isPlaceholderSessionTitle(trimmed),
  );
}

/// What a session started with [message] is called while nobody has named
/// it: its first line, without a heading's marks, cut near 60 characters.
String sessionTitleFromMessage(String message) {
  final line = message
      .split('\n')
      .map((l) => l.replaceFirst(RegExp(r'^\s*#+\s*'), '').trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '')
      .replaceAll(RegExp(r'\s+'), ' ');
  if (line.isEmpty) return kUnnamedSessionTitle;
  if (line.length <= 60) return line;
  final cut = line.substring(0, 60);
  final space = cut.lastIndexOf(' ');
  return '${(space > 30 ? cut.substring(0, space) : cut).trimRight()}…';
}
