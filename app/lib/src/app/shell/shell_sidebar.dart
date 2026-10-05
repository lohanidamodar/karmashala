import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_device_pane/pane.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../core/capabilities/capabilities.dart';
import '../../features/explorer/application/explorer_tree_provider.dart';
import '../../features/explorer/application/session_selection.dart';
import '../../features/explorer/presentation/agents_lens.dart';
import '../../features/explorer/presentation/explorer_panel.dart';
import '../../features/explorer/presentation/sidebar_chrome.dart';
import '../../features/notifications/presentation/attention_inbox_view.dart';
import '../../features/onboarding/presentation/quick_start_card.dart';
import 'devices_dock.dart';
import 'shell_area.dart';
import 'shell_shortcuts.dart';

/// What the list keeps above the quick start, its header included: room for
/// three rows and the start of a fourth, which reads as a list that scrolls.
const double _listRoom = 280;

/// The least the quick start takes: its header, to unfold it from.
const double _quickStartFloor = 48;

/// **The sidebar** (spec §4): the list for the area the strip picked, on the
/// sidebar's own tone. Every area draws the same [SidebarAreaHeader] and the
/// same list metrics ([Sidebar]); nothing between the list and the Devices
/// dock but space — regions are told apart by tone, not rules.
class ShellSidebar extends ConsumerWidget {
  const ShellSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final area = ref.watch(shellAreaProvider);
    final devicesArea = ref.watch(
      capabilitiesProvider.select((c) => c.devicesArea),
    );
    final selecting = ref.watch(
      sessionSelectionProvider.select((s) => s.active),
    );
    final mayStart = ref.watch(capabilitiesProvider.select((c) => c.mayStart));
    final list = switch (area) {
      ShellArea.sessions => _Area(
        title: 'Sessions',
        newLabel: 'New session',
        newIntent: const NewSessionIntent(),
        offersNew: mayStart,
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
          : LayoutBuilder(
              builder: (context, constraints) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: list),
                  // Beside the list, above the dock: never over the terminal,
                  // never more than half the sidebar, and never the list's room.
                  QuickStartCard(
                    maxHeight: (constraints.maxHeight - _listRoom).clamp(
                      _quickStartFloor,
                      math.max(_quickStartFloor, constraints.maxHeight * 0.5),
                    ),
                  ),
                  if (devicesArea) const ShellDevicesDock(),
                ],
              ),
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
    this.offersNew = true,
  });

  final String title;

  /// The area's own verbs, drawn before the +.
  final List<Widget> actions;
  final String newLabel;
  final Intent newIntent;
  final Widget child;

  /// False hides the +: a phone not granted what it makes.
  final bool offersNew;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SidebarAreaHeader(
        title: title,
        actions: actions,
        newLabel: newLabel,
        onNew: offersNew ? () => Actions.maybeInvoke(context, newIntent) : null,
      ),
      Expanded(child: child),
    ],
  );
}
