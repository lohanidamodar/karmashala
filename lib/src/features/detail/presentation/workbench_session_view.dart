import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../cli_detection/presentation/imported_session_view.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/presentation/session_transcript_view.dart';

/// The chat rendering of the selected session, as one surface of the workbench.
///
/// This is all that survives of the old "Detail" pane. The pane used to be a
/// container for four unrelated things — a transcript, a repository list, and
/// whatever the sidebar's index happened to point at. The repository list moved
/// to the Explorer tree (which already showed the same rows), the sidebar became
/// the side panel, and what is left is one job: show the conversation.
class WorkbenchSessionView extends ConsumerWidget {
  const WorkbenchSessionView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final importedId = ref.watch(selectedImportedSessionIdProvider);
    if (importedId != null) {
      return ImportedSessionView(sessionId: importedId);
    }
    final sessionId = ref.watch(selectedSessionIdProvider);
    if (sessionId != null) {
      return SessionTranscriptView(sessionId: sessionId);
    }
    return const PanePlaceholder(
      message: 'Open a session from the Explorer to see its conversation.',
    );
  }
}
