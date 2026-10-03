import 'package:agent_cli/read.dart' show SubagentRef;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/lineage.dart' show SessionLink;
import 'package:karmashala_ui/charts.dart' show formatCompactCount;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/phone_shell.dart' show phoneWorkbenchOpener;
import '../../../app/widgets/adaptive_modal.dart';
import '../../../core/util/clock_provider.dart';
import '../../cli_detection/presentation/subagent_turns_tile.dart';
import '../../explorer/application/explorer_actions.dart';
import '../application/session_subagents_providers.dart';

/// Opens session [sessionId]'s subagent panel: a side panel at width, a
/// bottom sheet on a phone.
Future<void> showSessionSubagents(BuildContext context, String sessionId) =>
    showAdaptiveSidePanel<void>(
      context: context,
      title: 'Subagents',
      builder: (_) => SessionSubagentsPanel(sessionId: sessionId),
    );

/// ⋯'s way into [SessionSubagentsPanel].
class SessionSubagentsButton extends StatelessWidget {
  const SessionSubagentsButton({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('session-subagents'),
    tooltip: 'Subagents and child sessions',
    icon: const Icon(AppIcons.treeStructure),
    onPressed: () => showSessionSubagents(context, sessionId),
  );
}

/// **The status line's count of a session's child sessions**, and how many
/// are working; nothing, and no width, while it has none. Opens the panel.
class SessionSubagentsBadge extends ConsumerWidget {
  const SessionSubagentsBadge({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (:count, :running) = ref.watch(sessionChildCountProvider(sessionId));
    if (count == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final working = SemanticColors.of(context).working;
    final children = count == 1 ? '1 child session' : '$count child sessions';
    final tooltip =
        '$children${running == 0 ? '' : ', $running working'}. '
        'Opens Subagents.';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            key: const ValueKey('session-subagents-badge'),
            onTap: () => showSessionSubagents(context, sessionId),
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    AppIcons.treeStructure,
                    size: Chrome.iconSmall,
                    color: running == 0 ? scheme.onSurfaceVariant : working,
                  ),
                  const SizedBox(width: Insets.xs),
                  Text(
                    running == 0 ? '$count' : '$count · $running working',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// **Every subagent and child session of one session**: what each was asked,
/// the agent and model it ran on, how far it got, how long it took, its tokens
/// and its last answer. A row opens the delegate's turns or the child session.
class SessionSubagentsPanel extends ConsumerWidget {
  const SessionSubagentsPanel({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sessionSubagentsProvider(sessionId));
    return switch (async) {
      AsyncValue(:final value?) => _Body(sessionId: sessionId, list: value),
      AsyncValue(hasError: true, :final error) => _Message(
        icon: AppIcons.warningCircle,
        text: error is SessionSubagentsUnavailable
            ? error.message
            : kSubagentsUnreadable,
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.sessionId, required this.list});

  final String sessionId;
  final SessionSubagentList list;

  @override
  Widget build(BuildContext context) {
    final note = list.note;
    final entries = list.entries;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      children: [
        if (entries.isEmpty)
          const _Message(
            icon: AppIcons.treeStructure,
            text: 'No subagents or child sessions yet.',
          ),
        for (final entry in entries)
          _EntryRow(parentSessionId: sessionId, entry: entry),
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.lg,
              Insets.sm,
              Insets.lg,
              0,
            ),
            child: Text(
              note,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(Insets.lg),
      child: Row(
        children: [
          Icon(icon, size: Chrome.iconSmall, color: scheme.onSurfaceVariant),
          const SizedBox(width: Insets.sm),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// How long [entry] ran, or has run so far; null when it never said when it
/// started.
Duration? subagentDuration(SessionSubagent entry, DateTime now) {
  final start = entry.startedAt;
  if (start == null) return null;
  final end = entry.endedAt ?? (entry.state.isLive ? now : null);
  if (end == null || end.isBefore(start)) return null;
  return end.difference(start);
}

String formatSubagentDuration(Duration span) {
  if (span.inSeconds < 60) return '${span.inSeconds}s';
  if (span.inMinutes < 60) {
    return '${span.inMinutes}m ${(span.inSeconds % 60).toString().padLeft(2, '0')}s';
  }
  return '${span.inHours}h ${(span.inMinutes % 60).toString().padLeft(2, '0')}m';
}

({IconData icon, String label}) _stateLook(SubagentState state) =>
    switch (state) {
      SubagentState.running => (icon: AppIcons.circleHalf, label: 'Running'),
      SubagentState.blocked => (
        icon: AppIcons.pauseCircle,
        label: 'Waiting on you',
      ),
      SubagentState.done => (icon: AppIcons.checkCircle, label: 'Done'),
      SubagentState.failed => (icon: AppIcons.xCircle, label: 'Failed'),
      SubagentState.stopped => (icon: AppIcons.stopCircle, label: 'Stopped'),
      SubagentState.unknown => (icon: AppIcons.question, label: 'Unknown'),
    };

/// How a child session came from its parent, in the panel's words.
String subagentLinkLabel(String? link) => switch (SessionLink.parse(link)) {
  SessionLink.spawn || null => 'child session',
  SessionLink.handoff => 'handed off',
  SessionLink.fork => 'forked',
};

class _EntryRow extends ConsumerWidget {
  const _EntryRow({required this.parentSessionId, required this.entry});

  final String parentSessionId;
  final SessionSubagent entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final look = _stateLook(entry.state);
    final duration = subagentDuration(entry, ref.read(clockProvider).nowUtc());
    final tokens = entry.tokens;
    final facts = [
      entry.agent ??
          (entry.kind == SubagentKind.childSession ? 'session' : 'subagent'),
      entry.model ?? 'model not recorded',
      look.label,
      if (duration != null) formatSubagentDuration(duration),
      if (tokens != null)
        '${formatCompactCount(tokens)} tokens'
      else if (entry.tokensGap == SubagentTokensGap.tooLarge)
        'tokens not counted (large record)'
      else
        'tokens not recorded',
    ].join(' · ');
    final result = entry.finalResult;
    final color = switch (entry.state) {
      SubagentState.failed => scheme.error,
      SubagentState.blocked => scheme.tertiary,
      SubagentState.done => scheme.primary,
      _ => scheme.onSurfaceVariant,
    };
    return InkWell(
      key: ValueKey('subagent-${entry.id}'),
      onTap: () => _open(context, ref),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Touch.target),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.lg,
            vertical: Insets.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  look.icon,
                  size: Chrome.iconSmall,
                  color: color,
                  semanticLabel: look.label,
                ),
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        if (entry.kind == SubagentKind.childSession)
                          Padding(
                            padding: const EdgeInsets.only(left: Insets.xs),
                            child: Text(
                              subagentLinkLabel(entry.link),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                    Text(
                      facts,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (result != null)
                      Padding(
                        padding: const EdgeInsets.only(top: Insets.xs),
                        child: Text(
                          result,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final childId = entry.childSessionId;
    if (childId != null) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      final showWorkbench = phoneWorkbenchOpener(context, ref);
      final actions = ref.read(explorerActionsProvider);
      Navigator.of(context).maybePop();
      final opened = await actions.openNative(childId);
      if (!opened.isFailure) showWorkbench?.call();
      final message = opened.message;
      if (message != null) {
        messenger?.showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    }
    final path = entry.transcriptPath;
    await showAdaptiveModal<void>(
      context: context,
      title: entry.title,
      heightFactor: 0.8,
      builder: (_) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
        child: path == null
            ? SelectableText(
                entry.finalResult ?? 'This subagent left no record to open.',
              )
            : SubagentTurnsTile(
                reference: SubagentRef(
                  toolUseId: entry.id,
                  filePath: path,
                  agentType: entry.agent ?? '',
                  description: entry.title,
                  spawnDepth: 1,
                  model: entry.model,
                ),
                sessionId: parentSessionId,
                initiallyExpanded: true,
              ),
      ),
    );
  }
}
