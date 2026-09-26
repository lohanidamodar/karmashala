import '../../workspaces/data/workspace_data.dart';
import 'package:riverpod/riverpod.dart';

import '../../sessions/application/session_providers.dart';

/// Where a terminal selection came from. A plain shell can say nothing, and
/// **that is an answer**: nothing falls back to the Explorer's selection.
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
      final rows = ref.read(sessionsDataProvider).getByPaneIds([paneId]);
      if (rows.isEmpty) return TerminalSelectionSource.none;
      final session = rows.first;
      return TerminalSelectionSource(
        sessionId: session.id,
        repositoryId: session.repositoryId,
        projectId: ref
            .read(workspaceDataProvider)
            .repository(session.repositoryId)
            ?.projectId,
      );
    });

/// A selection as the single line a todo is: a drag down a terminal carries
/// each row's padding, so runs of whitespace collapse. Nothing is truncated.
String todoLineFrom(String selection) =>
    selection.replaceAll(RegExp(r'\s+'), ' ').trim();

/// How many lines [selection] spans, so the composer can say what it joined.
/// Zero for a selection that caught nothing but blanks.
int selectionLineCount(String selection) {
  final trimmed = selection.trim();
  if (trimmed.isEmpty) return 0;
  return trimmed.split(RegExp(r'\r\n|\r|\n')).length;
}
