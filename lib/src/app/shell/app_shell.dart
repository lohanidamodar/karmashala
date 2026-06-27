import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/detail/presentation/detail_panel.dart';
import '../../features/explorer/presentation/explorer_panel.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/terminal/application/terminal_controller.dart';
import '../../features/terminal/presentation/terminal_view.dart';
import 'shell_shortcuts.dart';
import 'shell_state.dart';

/// The adaptive two-pane desktop shell: Explorer | Detail.
///
/// Layout adapts to the available width:
/// * **Wide/Medium** (≥ 760): Explorer tree beside the Detail view, with the
///   Explorer collapsible via `Ctrl+B`.
/// * **Narrow** (< 760): a single pane (the focused one) with a bottom selector.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  static const double _mediumBreakpoint = 760;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(shellControllerProvider);
    final terminalVisible = ref.watch(terminalVisibleProvider);
    return ShellShortcuts(
      child: Scaffold(
        appBar: const _ShellAppBar(),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth >= _mediumBreakpoint) {
                        return _SplitLayout(shell: shell);
                      }
                      return _NarrowLayout(shell: shell);
                    },
                  ),
                ),
              ),
              if (terminalVisible)
                const SizedBox(height: 220, child: TerminalView()),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShellAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const _ShellAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terminalVisible = ref.watch(terminalVisibleProvider);
    return AppBar(
      titleSpacing: 16,
      title: Row(
        children: [
          Icon(
            Icons.auto_stories_outlined,
            size: 22,
            color: Theme.of(context).colorScheme.tertiary,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Chitragupta',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  'THE AGENT LEDGER',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 9,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => SettingsScreen.show(context),
        ),
        IconButton(
          tooltip: 'Toggle terminal (Ctrl+`)',
          isSelected: terminalVisible,
          icon: const Icon(Icons.terminal),
          onPressed: () => ref.read(terminalVisibleProvider.notifier).toggle(),
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}

/// Split: the Explorer tree beside the Detail view, Explorer collapsible.
class _SplitLayout extends StatelessWidget {
  const _SplitLayout({required this.shell});
  final ShellState shell;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shell.explorerPaneVisible) ...[
          const SizedBox(width: 320, child: ExplorerPanel()),
          const SizedBox(width: 8),
        ],
        const Expanded(child: DetailPanel()),
      ],
    );
  }
}

/// Narrow: only the focused pane, with a selector to switch panes.
class _NarrowLayout extends ConsumerWidget {
  const _NarrowLayout({required this.shell});
  final ShellState shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(shellControllerProvider.notifier);
    final Widget active = switch (shell.focusedPane) {
      ShellPane.explorer => const ExplorerPanel(),
      ShellPane.detail => const DetailPanel(),
    };
    return Column(
      children: [
        Expanded(child: active),
        const SizedBox(height: 8),
        SegmentedButton<ShellPane>(
          segments: const [
            ButtonSegment(
              value: ShellPane.explorer,
              icon: Icon(Icons.account_tree_outlined),
              label: Text('Explorer'),
            ),
            ButtonSegment(
              value: ShellPane.detail,
              icon: Icon(Icons.article_outlined),
              label: Text('Detail'),
            ),
          ],
          selected: {shell.focusedPane},
          onSelectionChanged: (selection) =>
              controller.focusPane(selection.first),
        ),
      ],
    );
  }
}
