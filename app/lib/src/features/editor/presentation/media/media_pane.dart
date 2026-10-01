import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../explorer/application/session_context.dart';
import '../../../files/application/server_file_opening.dart';
import '../../../notes/application/composer_draft.dart';
import '../../../sessions/application/session_providers.dart';
import '../../../sessions/application/session_ui_providers.dart';
import '../../../terminal/application/pane_owner_session.dart';
import '../../domain/document_id.dart';
import '../editor_menu_actions.dart';
import 'media_tab_view.dart';

/// A media file as the content of a document pane: [MediaTabView] with its
/// hand-on actions wired to the pane it sits in. The view draws; this decides
/// where *Attach to chat* goes and how a file this machine cannot reach is
/// opened.
class MediaPane extends ConsumerWidget {
  const MediaPane({required this.paneId, required this.hostPath, super.key});

  final String paneId;

  /// The document id (`document_id.dart`).
  final String hostPath;

  static const _noSession =
      'No agent session beside this file — open one in this group first.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The session this pane works for, else the one in focus — the same
    // fallback "Send selection to session" takes.
    final sessionId =
        ref.watch(sessionOwningPaneProvider(paneId)) ??
        ref.watch(focusedSessionIdProvider);
    final file = documentPathOf(hostPath);
    final opening = ref.watch(serverFileOpeningProvider);
    return MediaTabView(
      hostPath: hostPath,
      onCopyPath: () => copyToClipboard(context, file.path, 'Path'),
      // A file on an SSH host or behind a server elsewhere is brought here
      // first, so this works wherever there is a default app to hand it to.
      onOpenExternally: opening.canOpen
          ? () async {
              final outcome = await opening.openWithDefaultApp(file);
              if (!outcome.ok && context.mounted) {
                ScaffoldMessenger.maybeOf(
                  context,
                )?.showSnackBar(SnackBar(content: Text(outcome.error!)));
              }
            }
          : null,
      onAttachToChat: sessionId == null
          ? null
          : () {
              final title =
                  ref.read(sessionsDataProvider).getById(sessionId)?.title ??
                  'the session';
              final outcome = offerFileToSession(
                ref,
                sessionId: sessionId,
                file: file,
              );
              if (outcome != SessionOfferOutcome.outOfReach) {
                ref.read(selectedSessionIdProvider.notifier).select(sessionId);
              }
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(content: Text(sessionOfferMessage(outcome, title))),
              );
            },
      attachDisabledReason: _noSession,
    );
  }
}
