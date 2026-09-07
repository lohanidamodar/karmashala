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
/// [Chrome.statusBar] tall — the cheapest chrome in the shell, and the only
/// place that answers "is something running that I cannot see" without opening a
/// dialog. Every item is a button, because a status bar that reports a fact you
/// then have to go and find is half a control.
///
/// **Everything on it is about the window.** Two per-session chips used to sit
/// here and both have gone to the session's own bar: the model, and then the
/// account quota. See the comment on the row for why the quota could not stay.
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
    // and its sibling `_ChangesSurface` on an announcement that fires whether
    // or not the repository moved. See `selectedRepositoryProvider`.
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
        // Two groups with the slack between them, rather than one row with a
        // `Spacer`. The two look equivalent and are not: a `Flexible` child is
        // allotted a share of the free space and then sizes itself to its
        // content, and the share it does not use is **not** handed back to the
        // `Spacer` — under `MainAxisAlignment.start` it falls out at the end of
        // the row. Three loose `Flexible`s on one row came to some 500 blank
        // pixels past the panel toggle on a 1600px window. `spaceBetween` puts
        // every pixel of slack *between* the groups instead, so none of it can
        // escape to either end.
        //
        // The order is what each group answers: where you are, and what is
        // running. **Both are facts about the window**, which is now the whole
        // of this row's remit. The two chips that were not — the model a
        // session runs under, and the quota its account is spending — have both
        // moved to the session's own bar under the terminal. The quota was the
        // last of them: it is per *account*, and the window shows panes on
        // several, so one figure here reported whichever session the app
        // believed was focused and attributed its account's remaining quota to
        // every pane beside it.
        //
        // Every group is `Flexible`, and that is not decoration: a non-flex
        // child of a `Row` is laid out unbounded, and a `Flexible` inside an
        // unbounded row is silently inert rather than an error — which is how
        // the model chip lost the ability to give way and overflowed the
        // minimum window by 8.2px. The weights are the order in which they
        // yield. Where you are goes first, because a truncated branch is still
        // a branch; the counts go last, because "2 need you" abbreviated is
        // not a count of anything.
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
            // taken out. A loose `Flexible` is capped at its share even when
            // the other group leaves the row half empty, so these are not
            // preferences, they are budgets: this group needs 362px at 720x560
            // on the 1.3x OS text step, and the ratio is what reserves it.
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
                      // The Inbox's own glyph, not a warning sign: this is the
                      // same count, the same list and the same click as the
                      // rail.
                      icon: AppIcons.tray,
                      label: attention == 1
                          ? '1 needs you'
                          : '$attention need you',
                      emphasised: true,
                      // The same number the rail badges and the tray badges,
                      // and the same click: there is one inbox and three ways
                      // in.
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
