import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';
import 'side_panel_state.dart';

import '../../features/git/application/changes_providers.dart';
import '../../features/notifications/application/attention_inbox.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';

/// The window's bottom rule: where you are, and what is still running.
///
/// [Chrome.statusBar] tall — the cheapest chrome in the shell, and the only
/// place that answers "is something running that I cannot see" without opening a
/// dialog. Every item is a button, because a status bar that reports a fact you
/// then have to go and find is half a control.
class ShellStatusBar extends ConsumerWidget {
  const ShellStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final repoId = ref.watch(selectedRepositoryIdProvider);
    final repo = ref
        .watch(selectedProjectRepositoriesProvider)
        .where((r) => r.id == repoId)
        .firstOrNull;
    final branch = ref.watch(currentBranchProvider);
    // Two counts, not the state: the status bar has no other interest in the
    // terminal, and a process exiting anywhere used to repaint this whole row.
    final detached = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.detached.length),
    );
    final openTabs = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.tabs.length),
    );
    final panel = ref.watch(sidePanelProvider);
    final attention = ref.watch(attentionCountProvider);

    final style = theme.textTheme.labelSmall?.copyWith(
      letterSpacing: 0,
      fontWeight: FontWeight.w500,
      color: scheme.onSurfaceVariant,
    );

    return Container(
      // Scaled with the text, or the labels would clip at 125%+.
      height: Chrome.statusBarOf(context),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      child: DefaultTextStyle.merge(
        style: style,
        child: Row(
          children: [
            if (repo != null) ...[
              _Item(icon: AppIcons.bookBookmark, label: repo.name),
              _Item(
                icon: AppIcons.gitBranch,
                label: switch (branch) {
                  AsyncData(:final value) => value ?? 'detached',
                  AsyncError() => 'no git',
                  _ => '…',
                },
              ),
            ] else
              _Item(
                icon: AppIcons.bookBookmark,
                label: 'No repository selected',
              ),
            const Spacer(),
            _Item(
              icon: AppIcons.terminal,
              label:
                  '$openTabs tab'
                  '${openTabs == 1 ? '' : 's'}',
            ),
            if (detached > 0)
              _Item(
                icon: AppIcons.terminalWindow,
                label: '$detached in background',
                emphasised: true,
              ),
            if (attention > 0)
              _Item(
                // The Inbox's own glyph, not a warning sign: this is the
                // same count, the same list and the same click as the rail.
                icon: AppIcons.tray,
                label: attention == 1 ? '1 needs you' : '$attention need you',
                emphasised: true,
                // The same number the rail badges and the tray badges, and the
                // same click: there is one inbox and three ways in.
                onTap: () => ref
                    .read(sidePanelProvider.notifier)
                    .select(SidePanelSurface.inbox),
              ),
            _Item(
              icon: AppIcons.sidebarSimple,
              label: panel?.label ?? 'Panel closed',
              onTap: () => ref.read(sidePanelProvider.notifier).toggle(),
            ),
          ],
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.label,
    this.onTap,
    this.emphasised = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// Something is running that has no tab. Worth the accent; nothing else here
  /// is.
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colour = emphasised ? scheme.primary : scheme.onSurfaceVariant;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: colour),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colour),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      child: Tooltip(message: label, child: content),
    );
  }
}
