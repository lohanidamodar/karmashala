import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_device_pane/pane.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/explorer/application/explorer_tree_provider.dart';
import '../../features/explorer/application/session_selection.dart';
import '../../features/explorer/presentation/agents_lens.dart';
import '../../features/explorer/presentation/explorer_panel.dart';
import '../../features/explorer/presentation/sidebar_chrome.dart';
import '../../features/notifications/presentation/attention_inbox_view.dart';
import 'devices_dock.dart';
import 'shell_area.dart';
import 'shell_shortcuts.dart';

/// **The sidebar** (spec §4): the list for the area the strip picked, on the
/// sidebar's own tone. Every area draws the same [SidebarAreaHeader] and the
/// same list metrics ([Sidebar]); nothing between the list and the Devices
/// dock but space — regions are told apart by tone, not rules.
class ShellSidebar extends ConsumerWidget {
  const ShellSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final area = ref.watch(shellAreaProvider);
    final selecting = ref.watch(
      sessionSelectionProvider.select((s) => s.active),
    );
    final list = switch (area) {
      ShellArea.sessions => _Area(
        title: 'Sessions',
        newLabel: 'New session',
        newIntent: const NewSessionIntent(),
        actions: [
          IconButton(
            tooltip: selecting ? 'Done selecting' : 'Select several',
            isSelected: selecting,
            icon: const Icon(AppIcons.listChecks),
            onPressed: () =>
                ref.read(sessionSelectionProvider.notifier).toggleMode(),
          ),
        ],
        child: const AgentsPage(),
      ),
      // Draws its own header — the same [SidebarAreaHeader] — because its
      // verbs (the filter, the sync spinner) are the Explorer's own. The
      // machines' terminal groups are the Terminals area's, not listed here.
      ShellArea.projects => const ExplorerPanel(terminals: false),
      ShellArea.terminals => _Area(
        title: 'Terminals',
        newLabel: 'New terminal',
        newIntent: const NewTerminalTabIntent(),
        child: ExplorerTreeView(source: terminalsTreeProvider),
      ),
      ShellArea.devices => const DevicePane(),
      ShellArea.inbox => const AttentionInboxView(),
    };
    return ColoredBox(
      color: SurfaceTones.of(context).side,
      child: area == ShellArea.devices
          ? list
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: list),
                const ShellDevicesDock(),
              ],
            ),
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
    this.actions = const [],
  });

  final String title;

  /// The area's own verbs, drawn before the +.
  final List<Widget> actions;
  final String newLabel;
  final Intent newIntent;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SidebarAreaHeader(
        title: title,
        actions: actions,
        newLabel: newLabel,
        onNew: () => Actions.maybeInvoke(context, newIntent),
      ),
      Expanded(child: child),
    ],
  );
}
