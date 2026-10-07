import 'package:agent_cli/descriptors.dart' show AgentPlanItemState;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

import '../../../app/shell/phone_shell.dart';
import '../../explorer/application/agent_states.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../explorer/application/workspace_session_entry.dart';
import '../../notifications/application/notification_providers.dart';
import '../../sessions/presentation/approval_request_card.dart';
import '../../sessions/presentation/archive_session_action.dart';
import '../../sessions/presentation/end_session_action.dart';
import '../application/overview_board.dart';
import '../application/overview_providers.dart';
import '../application/overview_reads.dart';
import 'overview_quick_composer.dart';
import 'overview_session_parts.dart';

/// **The peek**: one session at a glance — what it is doing in words, its
/// open ask through the ask path every surface uses, its plan, its last
/// answer, the files it changed and its sub-sessions — a quick message, and
/// Open, Stop and Archive.
class OverviewPeek extends ConsumerWidget {
  const OverviewPeek({
    required this.card,
    required this.onClose,
    this.onPeek,
    super.key,
  });

  final OverviewCard card;
  final VoidCallback onClose;

  /// A sub-session was tapped: peek it instead.
  final ValueChanged<OverviewCard>? onPeek;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = card.entry;
    final id = entry.id;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = UiDensity.of(context).muted(theme);
    final agent = watchOverviewAgentName(ref, card);
    final place = watchOverviewPlace(ref, card);
    final native = entry.native;
    final live = native != null && sessionHasLiveProcess(ref, id);
    final archivable =
        native != null && !native.isArchived && !sessionIsLive(ref, native);
    final ended = card.state == AgentState.ended;
    final plan = ref.watch(overviewGlanceProvider(id)).asData?.value?.plan;
    final children =
        ref.watch(overviewBoardProvider.select((b) => b.children[id])) ??
        const <OverviewCard>[];

    Widget section(String title, Widget body) => Padding(
      padding: const EdgeInsets.only(top: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          EyebrowLabel(title, padding: const EdgeInsets.only(bottom: Insets.xs)),
          body,
        ],
      ),
    );

    return Semantics(
      container: true,
      label: 'Peek: ${entry.title}',
      child: SingleChildScrollView(
        key: const ValueKey('overview-peek'),
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: Insets.xs),
                  child: OverviewAgentRing(card: card, size: Insets.xxl),
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        [?agent, if (place.isNotEmpty) place].join(' · '),
                        key: const ValueKey('overview-peek-place'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                      if (card.breadcrumb case final parent?)
                        Text('↳ from $parent', style: muted),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close peek',
                  icon: const Icon(AppIcons.x),
                  onPressed: onClose,
                ),
              ],
            ),
            const SizedBox(height: Insets.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: OverviewStatePill(card: card),
            ),
            section('Doing now', OverviewActivityLine(card: card, maxLines: 3)),
            if (card.column == BoardColumn.needsYou)
              Padding(
                padding: const EdgeInsets.only(top: Insets.sm),
                child: ApprovalRequestCard(sessionId: id),
              ),
            if (plan != null)
              section(
                'Plan',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OverviewPlanLine(plan: plan),
                    const SizedBox(height: Insets.xs),
                    for (final item in plan.items.take(8))
                      _PlanItem(text: item.text, state: item.state),
                    if (plan.items.length > 8)
                      Text('+${plan.items.length - 8} more', style: muted),
                  ],
                ),
              ),
            section('Last answer', _LastAnswer(sessionId: id)),
            _Files(sessionId: id),
            if (children.isNotEmpty)
              section(
                'Sub-sessions · ${children.length}',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final child in children)
                      _SubSession(card: child, onTap: onPeek),
                  ],
                ),
              ),
            section('Message', OverviewQuickComposer(card: card)),
            const SizedBox(height: Insets.md),
            Divider(color: scheme.outlineVariant, height: 1),
            const SizedBox(height: Insets.sm),
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.xs,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('overview-peek-open'),
                  onPressed: () => openOverviewSession(context, ref, entry),
                  icon: const Icon(AppIcons.arrowSquareOut),
                  label: Text(ended && native != null ? 'Resume' : 'Open'),
                ),
                if (live)
                  TextButton.icon(
                    key: const ValueKey('overview-peek-stop'),
                    onPressed: () =>
                        endSessionFromRow(context, ref, id, title: entry.title),
                    icon: const Icon(AppIcons.stop),
                    label: const Text('Stop'),
                  ),
                if (archivable)
                  TextButton.icon(
                    key: const ValueKey('overview-peek-archive'),
                    onPressed: () =>
                        archiveSessionsFromUi(context, ref, [native]),
                    icon: const Icon(AppIcons.tray),
                    label: const Text('Archive'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanItem extends StatelessWidget {
  const _PlanItem({required this.text, required this.state});

  final String text;
  final AgentPlanItemState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final done = state == AgentPlanItemState.completed;
    final (icon, color, label) = switch (state) {
      AgentPlanItemState.completed => (AppIcons.checkCircle, semantic.idle, 'done'),
      AgentPlanItemState.inProgress => (
        AppIcons.circleHalf,
        semantic.working,
        'now',
      ),
      _ => (AppIcons.circle, scheme.onSurfaceVariant, 'to do'),
    };
    return Semantics(
      label: '$label: $text',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: Insets.hair * 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: Insets.hair * 2),
              child: Icon(icon, size: UiDensity.of(context).iconSmall, color: color),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: done ? scheme.onSurfaceVariant : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The last answer as markdown, a few lines with "More", or why there is none.
class _LastAnswer extends ConsumerStatefulWidget {
  const _LastAnswer({required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_LastAnswer> createState() => _LastAnswerState();
}

class _LastAnswerState extends ConsumerState<_LastAnswer> {
  var _more = false;

  /// How many lines of the answer show before "More".
  static const _shutLines = 6;

  /// [_shutLines] of the body text the markdown is set in, at this scale.
  double _shutHeight(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyMedium;
    final line = (body?.fontSize ?? Insets.lg) * (body?.height ?? 1.45);
    return MediaQuery.textScalerOf(context).scale(line) * _shutLines;
  }

  @override
  Widget build(BuildContext context) {
    final muted = UiDensity.of(context).muted(Theme.of(context));
    return ref
        .watch(overviewLastAnswerProvider(widget.sessionId))
        .when(
          loading: () => Text('Reading…', style: muted),
          error: (error, _) =>
              Text('The last answer could not be read: $error', style: muted),
          data: (answer) {
            final text = answer.text;
            if (text == null) {
              return Text(
                answer.why!,
                key: const ValueKey('overview-peek-no-answer'),
                style: muted,
              );
            }
            final long = text.length > 280 || '\n'.allMatches(text).length > 5;
            return Column(
              key: const ValueKey('overview-peek-answer'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: _more || !long
                        ? double.infinity
                        : _shutHeight(context),
                  ),
                  child: ClipRect(
                    child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      child: MarkdownMessage(text),
                    ),
                  ),
                ),
                if (long)
                  TextButton(
                    key: const ValueKey('overview-peek-more'),
                    onPressed: () => setState(() => _more = !_more),
                    child: Text(_more ? 'Less' : 'More'),
                  ),
              ],
            );
          },
        );
  }
}

/// "3 files changed" and their names, when the session's record says.
class _Files extends ConsumerWidget {
  const _Files({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref
        .watch(overviewChangedFilesProvider(sessionId))
        .asData
        ?.value;
    if (files == null || files.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);
    String name(String path) =>
        path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).lastOrNull ??
        path;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.lg),
      child: Column(
        key: const ValueKey('overview-peek-files'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EyebrowLabel(
            files.length == 1 ? '1 file changed' : '${files.length} files changed',
            padding: const EdgeInsets.only(bottom: Insets.xs),
          ),
          for (final path in files.take(6))
            Tooltip(
              message: path,
              child: Text(
                name(path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (files.length > 6) Text('+${files.length - 6} more', style: muted),
        ],
      ),
    );
  }
}

class _SubSession extends ConsumerWidget {
  const _SubSession({required this.card, this.onTap});

  final OverviewCard card;
  final ValueChanged<OverviewCard>? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final line = watchOverviewLine(ref, card);
    return InkWell(
      key: ValueKey('overview-peek-sub:${card.id}'),
      borderRadius: BorderRadius.circular(Radii.sm),
      onTap: onTap == null ? null : () => onTap!(card),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: Insets.hair * 2),
              child: OverviewStateGlyph(
                state: card.state,
                size: UiDensity.of(context).iconSmall + Insets.hair,
              ),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: card.entry.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(
                      text: '  $line',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
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
