import 'package:riverpod/riverpod.dart';

import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';

/// Where a terminal selection came from. A plain shell can say nothing, and
/// **that is an answer rather than a gap**: nothing falls back to the
/// Explorer's selection or a panel's filter, because provenance is a claim
/// about where the text *was*.
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

/// What the pane [paneId] can say about a selection taken out of it. Read as
/// the menu opens rather than watched — nothing draws it.
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

/// A selection as the single line a todo is: every run of whitespace becomes
/// one space, because a selection dragged down a terminal carries each row's
/// padding out to the right edge. Nothing is truncated or summarised — the
/// composer shows exactly what will be saved.
String todoLineFrom(String selection) =>
    selection.replaceAll(RegExp(r'\s+'), ' ').trim();

/// How many lines [selection] spans, so the composer can say what it joined.
/// Zero for a selection that caught nothing but blanks.
int selectionLineCount(String selection) {
  final trimmed = selection.trim();
  if (trimmed.isEmpty) return 0;
  return trimmed.split(RegExp(r'\r\n|\r|\n')).length;
}
