import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';
import 'side_panel_state.dart';

import '../../features/agents/presentation/usage_chip.dart';
import '../../features/git/application/changes_providers.dart';
import '../../features/notifications/application/attention_inbox.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/sessions/presentation/model_chip.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';

/// The window's bottom rule: where you are, and what is still running.
///
/// [Chrome.statusBar] tall — the cheapest chrome in the shell, and the only
/// place that answers "is something running that I cannot see" without opening a
/// dialog. Every item is a button, because a status bar that reports a fact you
/// then have to go and find is half a control.
class ShellStatusBar extends ConsumerWidget {
  const ShellStatusBar({super.key});

  /// Builds of this row's own items, counted so a cost test can prove that a
  /// usage change repaints the chip and leaves the rest of the row alone.
  @visibleForTesting
  static int debugItemBuildCount = 0;

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
        // Two groups with the slack between them, rather than one row with a
        // `Spacer`. The two look equivalent and are not: a `Flexible` child is
        // allotted a share of the free space and then sizes itself to its
        // content, and the share it does not use is **not** handed back to the
        // `Spacer` — under `MainAxisAlignment.start` it falls out at the end of
        // the row. With three loose `Flexible`s on one row (repository, branch,
        // the model chip) that came to some 500 blank pixels past the panel
        // toggle on a 1600px window, with the whole state group stranded in the
        // middle of the bar. With exactly two children, `spaceBetween` puts
        // every pixel of slack between them and none of it can escape right.
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Where you are. The elastic half: a long repository or branch is
            // what gives way at 720px and on a host whose system font is wider
            // than this one's.
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
            // What is running, hard against the right edge, with the panel
            // toggle last.
            //
            // `Flexible` as well, and it has to be: that is what gives this
            // group a *bounded* width, and a bounded width is the only thing
            // that lets the model chip inside it shrink. In a non-flex slot the
            // group is laid out unbounded, where `Flexible` is silently inert —
            // and the longest model name a shipped agent has then overflowed
            // 720x560 at 1.3x text by 8.2px.
            //
            // Four fifths of the slack, against the left group's one. Not a
            // tuning knob: it is the ordering the row has always had, said in
            // the only place the layout can hear it. Where you are is elastic
            // and abbreviates well — a truncated branch is still a branch —
            // while every item on this side is a count or a state that means
            // nothing abbreviated. An even split gave this group 360px of a
            // 720px window and overflowed it by 90.
            Flexible(
              flex: 4,
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
                  // Both `const`, so a rebuild of this row cannot rebuild
                  // either chip and neither a quota nor a model change can
                  // rebuild the row — each subscription is the chip's own, and
                  // it is the only thing that repaints for it.
                  //
                  // The model before the quota: it is the fact about the
                  // session you are looking at that you can *act* on, and the
                  // one whose label changes when you change it.
                  //
                  // The only item here that gives way. A model name is the one
                  // width on this side that is not ours to predict — `Gemini
                  // 3.7 Flash (Medium)` is a real one — and the chip's own 72px
                  // cap is in logical pixels, so the text still grows with the
                  // OS text step.
                  const Flexible(child: FocusedModelChip()),
                  const UsageChip(),
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
          Icon(icon, size: 12, color: colour),
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
