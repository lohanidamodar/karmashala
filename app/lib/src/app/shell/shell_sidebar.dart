import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_device_pane/pane.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/explorer/presentation/explorer_panel.dart';
import '../../features/notifications/presentation/attention_inbox_view.dart';
import 'shell_area.dart';

/// **The sidebar** (spec §4): the list for the area the strip picked, on the
/// sidebar's own tone. Sessions and Terminals show the Explorer until their
/// own lists land (UI overhaul plan, stage 3).
class ShellSidebar extends ConsumerWidget {
  const ShellSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final area = ref.watch(shellAreaProvider);
    return ColoredBox(
      color: SurfaceTones.of(context).side,
      child: switch (area) {
        ShellArea.sessions ||
        ShellArea.projects ||
        ShellArea.terminals => const ExplorerPanel(),
        ShellArea.devices => const DevicePane(),
        ShellArea.inbox => const AttentionInboxView(),
      },
    );
  }
}
