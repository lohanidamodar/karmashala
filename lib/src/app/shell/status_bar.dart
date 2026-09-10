import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';
import 'side_panel_state.dart';

import '../../features/git/application/changes_providers.dart';
import '../../features/notifications/application/attention_inbox.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';

/// The window's bottom rule: where you are, and what is still running.
///
/// Every item is a button — a status bar that reports a fact you then have to go
/// and find is half a control. Everything on it is about the **window**; the two
/// per-session chips it used to carry are on the session's own bar now.
class ShellStatusBar extends ConsumerWidget {
  const ShellStatusBar({super.key});

  /// Builds of this row's own items, counted so a cost test can prove that a
  /// per-session change — a model, a quota — does not reach this row at all.
  @visibleForTesting
  static int debugItemBuildCount = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // The row, not the list it came out of: watching the list put this widget
    // on an announcement that fires whether or not the repository moved.
    final repo = ref.watch(selectedRepositoryProvider);
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
        // Two groups with the slack between them, not one row with a `Spacer`:
        // a `Flexible`'s unused share is not handed back, and three loose ones
        // left some 500 blank pixels at the end of a 1600px row. Each group is
        // `Flexible` because a non-flex child of a `Row` is laid out unbounded,
        // where a `Flexible` is silently inert — which is how the model chip
        // overflowed the minimum window by 8.2px. The weights are the order in
        // which they yield.
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (repo != null) ...[
                    Flexible(
                      child: _Item(
                        icon: AppIcons.bookBookmark,
                        label: repo.name,
                      ),
                    ),
                    Flexible(
                      child: _Item(
                        icon: AppIcons.gitBranch,
                        label: switch (branch) {
                          AsyncData(:final value) => value ?? 'detached',
                          AsyncError() => 'no git',
                          _ => '…',
                        },
                      ),
                    ),
                  ] else
                    Flexible(
                      child: _Item(
                        icon: AppIcons.bookBookmark,
                        label: 'No repository selected',
                      ),
                    ),
                ],
              ),
            ),
            // 1 : 5, from the measured 1 : 4 : 5 with the quota's middle group
            // taken out: this group needs 362px at 720x560 on the 1.3x text
            // step, and the ratio is what reserves it.
            Flexible(
              flex: 5,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                      // The Inbox's own glyph, not a warning sign: the same
                      // count, the same list and the same click as the rail.
                      icon: AppIcons.tray,
                      label: attention == 1
                          ? '1 needs you'
                          : '$attention need you',
                      emphasised: true,
                      // One inbox, three ways in.
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
    ShellStatusBar.debugItemBuildCount++;
    final scheme = Theme.of(context).colorScheme;
    final colour = emphasised ? scheme.primary : scheme.onSurfaceVariant;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: Chrome.iconSmall, color: colour),
          const SizedBox(width: 5),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colour),
              ),
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
