import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';

/// Where a terminal selection came from.
///
/// A pane running one of our sessions can say which session, which repository
/// and therefore which project the characters were taken from. A plain shell
/// can say none of it, and **that is an answer rather than a gap** — the rule
/// `Todo.projectId` and `Note.projectId` both already state.
///
/// Nothing here falls back to the Explorer's selection, to the tab's other
/// panes, or to whatever project a panel happens to be filtered to. Filing is
/// the user's and can be changed later; provenance is a claim about where the
/// text *was*, and the pane next door is not where it was.
class TerminalSelectionSource {
  const TerminalSelectionSource({
    this.sessionId,
    this.repositoryId,
    this.projectId,
  });

  /// A plain shell: nothing to tag, and nothing invented to fill the space.
  static const none = TerminalSelectionSource();

  final String? sessionId;
  final String? repositoryId;
  final String? projectId;

  bool get fromSession => sessionId != null;
}

/// What the pane [paneId] can say about a selection taken out of it.
///
/// Read as the menu opens rather than watched: nothing draws this, and the
/// answer only has to be right at the moment the user asks for it.
final terminalSelectionSourceProvider = Provider.autoDispose
    .family<TerminalSelectionSource, String>((ref, paneId) {
      final rows = ref.read(sessionDaoProvider).getByPaneIds([paneId]);
      if (rows.isEmpty) return TerminalSelectionSource.none;
      final session = rows.first;
      return TerminalSelectionSource(
        sessionId: session.id,
        repositoryId: session.repositoryId,
        projectId: ref
            .read(repositoryDaoProvider)
            .getById(session.repositoryId)
            ?.projectId,
      );
    });

/// A selection as the single line a todo is.
///
/// Every run of whitespace becomes one space. Joining the lines is not enough
/// on its own: a selection dragged down a terminal carries each row's padding
/// out to the right-hand edge, so a two-line capture arrives with a gulf in
/// the middle of it.
///
/// Nothing is truncated and nothing is summarised. The composer this fills
/// shows exactly what will be saved, so the collapse is something the user
/// reads and can undo by hand — see `showNewTodoDialog`.
String todoLineFrom(String selection) =>
    selection.replaceAll(RegExp(r'\s+'), ' ').trim();

/// How many lines [selection] spans, so the composer can say what it joined.
/// Zero for a selection that caught nothing but blanks.
int selectionLineCount(String selection) {
  final trimmed = selection.trim();
  if (trimmed.isEmpty) return 0;
  return trimmed.split(RegExp(r'\r\n|\r|\n')).length;
}
