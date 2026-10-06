import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_shell.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/agent_states.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../explorer/application/workspace_session_entry.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/application/session_chat_source.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/presentation/approval_request_card.dart';
import '../../sessions/presentation/archive_session_action.dart';
import '../../sessions/presentation/end_session_action.dart';
import '../application/overview_board.dart';
import '../application/overview_card_line.dart';
import '../application/overview_providers.dart';

/// **The peek**: one card's last answer, its open ask through the ask path
/// every other surface uses, and the actions that fit its state. The only
/// place the Overview reads anything per session that is not already in
/// memory — the transcript — and only for the card peeked.
class OverviewPeek extends ConsumerWidget {
  const OverviewPeek({required this.card, required this.onClose, super.key});

  final OverviewCard card;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = card.entry;
    final id = entry.id;
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    ref.watch(agentSessionStatusProvider(id));
    final details = ref.watch(overviewInboxDetailsProvider(id));
    final line = overviewContextLine(
      state: card.state,
      report: ref.read(sessionStatusLookupProvider)(id),
      detailOf: (kind) => details[kind],
      activityAt: entry.activityAt,
      now: ref.read(clockProvider).nowUtc(),
    );
    final native = entry.native;
    final live = native != null && sessionHasLiveProcess(ref, id);
    final archivable =
        native != null && !native.isArchived && !sessionIsLive(ref, native);
    final ended = card.state == AgentState.ended;
    return Semantics(
      container: true,
      label: 'Peek: ${entry.title}',
      child: SingleChildScrollView(
        key: const ValueKey('overview-peek'),
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Close peek',
                  icon: const Icon(AppIcons.x),
                  onPressed: onClose,
                ),
              ],
            ),
            Text('${card.state.label} · $line', style: muted),
            if (card.breadcrumb case final parent?)
              Text('From $parent', style: muted),
            const SizedBox(height: Insets.sm),
            if (card.column == BoardColumn.needsYou)
              ApprovalRequestCard(sessionId: id),
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.xs,
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('overview-peek-open'),
                  onPressed: () => openOverviewSession(context, ref, entry),
                  icon: const Icon(AppIcons.play),
                  label: Text(ended && native != null ? 'Resume' : 'Open'),
                ),
                if (live)
                  OutlinedButton.icon(
                    key: const ValueKey('overview-peek-stop'),
                    onPressed: () =>
                        endSessionFromRow(context, ref, id, title: entry.title),
                    icon: const Icon(AppIcons.stop),
                    label: const Text('Stop'),
                  ),
                if (archivable)
                  OutlinedButton.icon(
                    key: const ValueKey('overview-peek-archive'),
                    onPressed: () =>
                        archiveSessionsFromUi(context, ref, [native]),
                    icon: const Icon(AppIcons.tray),
                    label: const Text('Archive'),
                  ),
              ],
            ),
            if (native != null) ...[
              const SizedBox(height: Insets.md),
              Text('Last answer', style: theme.textTheme.labelMedium),
              const SizedBox(height: Insets.xs),
              _LastAnswer(sessionId: id),
            ],
          ],
        ),
      ),
    );
  }
}

class _LastAnswer extends ConsumerWidget {
  const _LastAnswer({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = UiDensity.of(context).muted(Theme.of(context));
    final rows = ref.watch(sessionChatTranscriptProvider(sessionId));
    return rows.when(
      loading: () => Text('Reading…', style: muted),
      error: (_, _) => Text('The transcript could not be read.', style: muted),
      data: (rows) {
        String? last;
        for (final row in rows.reversed) {
          if (row.role == 'agent' && row.text.trim().isNotEmpty) {
            last = row.text.trim();
            break;
          }
        }
        if (last == null) {
          return Text('No answer recorded yet.', style: muted);
        }
        return SelectableText(last, maxLines: 14);
      },
    );
  }
}

/// Opens [entry] where the session lists would — resuming one that ended —
/// and raises the workbench on the phone.
Future<void> openOverviewSession(
  BuildContext context,
  WidgetRef ref,
  WorkspaceSessionEntry entry,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final actions = ref.read(explorerActionsProvider);
  final showWorkbench = phoneWorkbenchOpener(context, ref);
  final native = entry.native;
  final imported = entry.imported;
  final ExplorerResult? result;
  if (native != null) {
    result = await actions.openNative(native.id);
  } else if (imported != null) {
    result = await actions.openImported(imported);
  } else {
    focusWatchedSession(ref.container, openId: entry.id, imported: false);
    result = null;
  }
  if (!(result?.isFailure ?? false)) showWorkbench?.call();
  final message = result?.message;
  if (message != null) {
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}
