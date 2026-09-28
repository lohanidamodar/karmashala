import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_device_pane/pane.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/explorer/application/explorer_tree_provider.dart';
import '../../features/explorer/presentation/agents_lens.dart';
import '../../features/explorer/presentation/explorer_panel.dart';
import '../../features/notifications/presentation/attention_inbox_view.dart';
import 'shell_area.dart';
import 'shell_shortcuts.dart';

/// **The sidebar** (spec §4): the list for the area the strip picked, on the
/// sidebar's own tone.
class ShellSidebar extends ConsumerWidget {
  const ShellSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final area = ref.watch(shellAreaProvider);
    return ColoredBox(
      color: SurfaceTones.of(context).side,
      child: switch (area) {
        ShellArea.sessions => const _Area(
          title: 'Sessions',
          newLabel: 'New session',
          newIntent: NewSessionIntent(),
          child: AgentsPage(),
        ),
        ShellArea.projects => const ExplorerPanel(),
        ShellArea.terminals => _Area(
          title: 'Terminals',
          newLabel: 'New terminal',
          newIntent: const NewTerminalTabIntent(),
          child: ExplorerTreeView(source: terminalsTreeProvider),
        ),
        ShellArea.devices => const DevicePane(),
        ShellArea.inbox => const AttentionInboxView(),
      },
    );
  }
}

/// An area's header over its list: the name, and the way to make a new one —
/// the same intent the keyboard sends, so the two cannot disagree.
class _Area extends StatelessWidget {
  const _Area({
    required this.title,
    required this.newLabel,
    required this.newIntent,
    required this.child,
  });

  final String title;
  final String newLabel;
  final Intent newIntent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.only(left: Insets.lg, right: Insets.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: newLabel,
                  icon: const Icon(AppIcons.plus),
                  onPressed: () => Actions.maybeInvoke(context, newIntent),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
