import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/detail/presentation/detail_panel.dart';
import '../../features/projects/presentation/projects_panel.dart';
import '../../features/sessions/presentation/sessions_panel.dart';
import 'shell_shortcuts.dart';
import 'shell_state.dart';

/// The adaptive three-pane desktop shell: Projects | Sessions | Detail.
///
/// Layout adapts to the available width:
/// * **Wide** (≥ 1100): all three panes side by side.
/// * **Medium** (≥ 760): Sessions | Detail, with Projects collapsible.
/// * **Narrow** (< 760): a single pane (the focused one) with a bottom selector.
///
/// At medium/wide widths the projects pane can also be toggled with `Ctrl+B`.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  static const double _wideBreakpoint = 1100;
  static const double _mediumBreakpoint = 760;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(shellControllerProvider);
    return ShellShortcuts(
      child: Scaffold(
        appBar: const _ShellAppBar(),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                if (width >= _wideBreakpoint) {
                  return _WideLayout(shell: shell);
                }
                if (width >= _mediumBreakpoint) {
                  return _MediumLayout(shell: shell);
                }
                return _NarrowLayout(shell: shell);
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ShellAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _ShellAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      titleSpacing: 16,
      title: Row(
        children: [
          const Icon(Icons.hub_outlined, size: 20),
          const SizedBox(width: 10),
          Text('Chitragupta', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 10),
          Text(
            'Agent Development Environment',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Wide: three resizable-feeling columns via flex weights.
class _WideLayout extends StatelessWidget {
  const _WideLayout({required this.shell});
  final ShellState shell;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shell.projectsPaneVisible) ...[
          const Expanded(flex: 3, child: ProjectsPanel()),
          const SizedBox(width: 8),
        ],
        const Expanded(flex: 4, child: SessionsPanel()),
        const SizedBox(width: 8),
        const Expanded(flex: 5, child: DetailPanel()),
      ],
    );
  }
}

/// Medium: Sessions | Detail, projects collapsible to the left.
class _MediumLayout extends StatelessWidget {
  const _MediumLayout({required this.shell});
  final ShellState shell;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shell.projectsPaneVisible) ...[
          const SizedBox(width: 260, child: ProjectsPanel()),
          const SizedBox(width: 8),
        ],
        const Expanded(flex: 4, child: SessionsPanel()),
        const SizedBox(width: 8),
        const Expanded(flex: 5, child: DetailPanel()),
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
      ShellPane.projects => const ProjectsPanel(),
      ShellPane.sessions => const SessionsPanel(),
      ShellPane.detail => const DetailPanel(),
    };
    return Column(
      children: [
        Expanded(child: active),
        const SizedBox(height: 8),
        SegmentedButton<ShellPane>(
          segments: const [
            ButtonSegment(
              value: ShellPane.projects,
              icon: Icon(Icons.folder_outlined),
              label: Text('Projects'),
            ),
            ButtonSegment(
              value: ShellPane.sessions,
              icon: Icon(Icons.chat_bubble_outline),
              label: Text('Sessions'),
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
