import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_terminal_core/geometry.dart' show chatPaneId;

import '../../features/sessions/application/session_status_providers.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'tab_picker.dart';
import 'workbench.dart' show terminalTabEntries, workbenchHostedSession;

/// The session switcher field's height and corner (board N4).
const double _switcherHeight = 32;
const double _switcherRadius = 7;

/// **The session switcher** (spec §5, board N4 Compact): a field on the
/// raised tone naming the tab in front with what its agent is doing, and a
/// caret — a press picks another. The phone's workbench wears it on top.
class ShellTabSwitcher extends ConsumerWidget {
  const ShellTabSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabId = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.activeTab?.id),
    );
    // A session shown without a tab of its own is the one on screen.
    final hosted = workbenchHostedSession(ref);
    final String title = hosted != null
        ? hosted.title
        : tabId == null
        ? 'No tab'
        : ref.watch(terminalTabTitleProvider(tabId));
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: 'Switch tab',
      child: Material(
        color: SurfaceTones.of(context).raised,
        borderRadius: BorderRadius.circular(_switcherRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(_switcherRadius),
          onTap: () => TabPicker.show(context, terminalTabEntries),
          child: Container(
            constraints: const BoxConstraints(minHeight: _switcherHeight),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                const ShellActiveTabGlyph(),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UiDensity.of(context).rowTitle(theme),
                  ),
                ),
                const SizedBox(width: Insets.xs),
                Icon(
                  AppIcons.caretDown,
                  size: Chrome.iconSmall,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the agent in the tab in front is doing — the spinner, the shield —
/// ahead of the tab's name in the session switcher and the Zen bar, followed
/// by its gap. Nothing, and no width, for a tab with no agent in it.
class ShellActiveTabGlyph extends ConsumerWidget {
  const ShellActiveTabGlyph({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Joined, so the selection compares by value: the tab's pane list is a
    // new list on every change to the controller's state. A session shown
    // without a tab is read through its chat pane's id.
    final hosted = workbenchHostedSession(ref);
    final panes = hosted != null
        ? chatPaneId(hosted.id)
        : ref.watch(
            terminalSessionsControllerProvider.select(
              (s) => s.activeTab?.layout.panes.join('\n'),
            ),
          );
    if (panes == null || panes.isEmpty) return const SizedBox.shrink();
    final status = mostUrgentAgentActivity([
      for (final paneId in panes.split('\n'))
        ref.watch(paneAgentActivityProvider(paneId)),
    ]);
    if (status == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: Insets.sm),
      child: StatusGlyph(
        status: status,
        size: Chrome.iconSmall,
        semanticLabel: 'Agent: ${agentStatusAppearance(status).label}',
        askShield: true,
      ),
    );
  }
}
