import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';

import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/detail/presentation/workbench_session_view.dart';
import '../../features/sessions/application/session_providers.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import '../../features/sessions/domain/session.dart';
import '../../features/sessions/presentation/agent_status_badge.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../../features/terminal/presentation/terminal_panel.dart';

/// The primary content area: one tab strip across the top, the work underneath.
///
/// Loop 47 moved the terminal here from a 280px bottom dock. A dock is right for
/// an *editor*-primary app; Chitragupta decided to be terminal-primary, and none
/// of the products it is learning from (Orca, cmux, Warp, Ghostty) put the
/// terminal anywhere but the middle of the window.
///
/// **One session, two views.** A session that runs in one of our panes is not
/// two things. Its chat rendering and its terminal are two surfaces of the same
/// record, switched by the toggle at the right of the strip — which is why the
/// switch reattaches and focuses rather than starting anything. Which surface is
/// showing is [terminalVisibleProvider]: `true` is the terminal, `false` is the
/// conversation. Nothing else needed a new provider.
class WorkbenchView extends ConsumerStatefulWidget {
  const WorkbenchView({super.key});

  @override
  ConsumerState<WorkbenchView> createState() => _WorkbenchViewState();
}

class _WorkbenchViewState extends ConsumerState<WorkbenchView> {
  void _showSession() => ref.read(terminalVisibleProvider.notifier).set(false);

  /// Reveals the pane the selected session is already running in. Starts and
  /// stops nothing: a detached pane comes back as a tab, one already in a tab is
  /// simply focused.
  void _showTerminalFor(String? paneId) {
    if (paneId != null) {
      final terminals = ref.read(terminalSessionsControllerProvider.notifier);
      terminals
        ..reattachSession(paneId)
        ..focusPane(paneId);
      ref.read(sessionsRevisionProvider.notifier).bump();
    }
    ref.read(terminalVisibleProvider.notifier).set(true);
  }

  @override
  Widget build(BuildContext context) {
    // Picking a session in the Explorer is a request to read it, so the
    // workbench comes back to the conversation. Kept as a listener rather than
    // a build-time branch so the user can still switch to the terminal and stay
    // there.
    ref.listen(selectedSessionIdProvider, (_, next) {
      if (next != null) _showSession();
    });
    ref.listen(selectedImportedSessionIdProvider, (_, next) {
      if (next != null) _showSession();
    });

    final scheme = Theme.of(context).colorScheme;
    final session = _selectedSession();
    final terminals = ref.watch(terminalSessionsControllerProvider);
    // With nothing to read, the workbench is the terminal — an empty middle
    // would be worse than the surface the app is primarily about.
    final onTerminal = ref.watch(terminalVisibleProvider) || session == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabStrip(
          session: session,
          onTerminal: onTerminal,
          terminals: terminals,
          onShowSession: _showSession,
          onShowTerminal: _showTerminalFor,
        ),
        const Divider(height: 1),
        Expanded(
          child: ColoredBox(
            color: scheme.surfaceContainerLowest,
            // With two surfaces, an IndexedStack rather than a branch: the
            // conversation keeps its scroll position while the terminal is up,
            // and — the Loop 26 property — the hidden one paints nothing. With
            // one surface there is nothing to keep alive, so it is not paid for.
            child: session == null
                ? const TerminalPaneStack()
                : IndexedStack(
                    index: onTerminal ? 0 : 1,
                    children: const [
                      TerminalPaneStack(),
                      WorkbenchSessionView(),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /// The session the Explorer has selected, if any, as the workbench needs it:
  /// a title, whether it has a pane of ours, and whether it is one of ours at
  /// all (imported CLI sessions have no pane and no live status).
  _WorkbenchSession? _selectedSession() {
    ref.watch(sessionsRevisionProvider);
    final importedId = ref.watch(selectedImportedSessionIdProvider);
    if (importedId != null) {
      final imported = ref.read(importedSessionDaoProvider).getById(importedId);
      return _WorkbenchSession(
        id: importedId,
        title: imported?.displayTitle ?? 'Session',
        paneId: null,
        native: false,
      );
    }
    final sessionId = ref.watch(selectedSessionIdProvider);
    if (sessionId == null) return null;
    final Session? record = ref.read(sessionDaoProvider).getById(sessionId);
    return _WorkbenchSession(
      id: sessionId,
      title: record?.title ?? 'Session',
      paneId: record?.paneId,
      native: true,
    );
  }
}

class _WorkbenchSession {
  const _WorkbenchSession({
    required this.id,
    required this.title,
    required this.paneId,
    required this.native,
  });

  final String id;
  final String title;

  /// The pane this session runs in, when it runs in one of ours. Null for an
  /// imported CLI session or one opened in an external terminal — those have a
  /// conversation to read but no terminal of ours to switch to.
  final String? paneId;
  final bool native;
}

class _TabStrip extends ConsumerWidget {
  const _TabStrip({
    required this.session,
    required this.onTerminal,
    required this.terminals,
    required this.onShowSession,
    required this.onShowTerminal,
  });

  final _WorkbenchSession? session;
  final bool onTerminal;
  final TerminalSessionsState terminals;
  final VoidCallback onShowSession;
  final ValueChanged<String?> onShowTerminal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final active = terminals.activeTabId;

    return Container(
      height: Chrome.tabStrip,
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                if (session != null)
                  WorkbenchTabChip(
                    selected: !onTerminal,
                    onTap: onShowSession,
                    label: session!.title,
                    tooltip: 'Conversation · ${session!.title}',
                    leading: Padding(
                      padding: const EdgeInsets.only(right: Insets.sm),
                      child: session!.native
                          ? AgentStatusBadge(sessionId: session!.id)
                          : const Icon(
                              AppIcons.clockCounterClockwise,
                              size: Chrome.iconSmall,
                            ),
                    ),
                    trailing: IconButton(
                      tooltip: 'Close conversation',
                      iconSize: 13,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 20,
                        minHeight: 20,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(AppIcons.x),
                      onPressed: () {
                        ref
                            .read(selectedSessionIdProvider.notifier)
                            .select(null);
                        ref
                            .read(selectedImportedSessionIdProvider.notifier)
                            .select(null);
                      },
                    ),
                  ),
                for (final tab in terminals.tabs)
                  TerminalTabChip(
                    title: sessions.titleForTab(tab.id),
                    liveness: sessions.livenessForTab(tab.id),
                    selected: onTerminal && tab.id == active,
                    onTap: () {
                      sessions.activateTab(tab.id);
                      onShowTerminal(null);
                    },
                    onClose: () => sessions.closeTab(tab.id),
                    onEnd: () => sessions.closeTab(tab.id, detach: false),
                  ),
              ],
            ),
          ),
          if (session?.paneId != null)
            _ViewToggle(
              onTerminal: onTerminal,
              onChat: onShowSession,
              onTerminalView: () => onShowTerminal(session!.paneId),
            ),
          const TerminalToolbar(),
          const _ZenButton(),
          const SizedBox(width: Insets.xs),
        ],
      ),
    );
  }
}

/// The two renderings of one session. Not a navigation control: both sides show
/// the same record, the same PTY and the same lifecycle.
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({
    required this.onTerminal,
    required this.onChat,
    required this.onTerminalView,
  });

  final bool onTerminal;
  final VoidCallback onChat;
  final VoidCallback onTerminalView;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget half(IconData icon, String tip, bool selected, VoidCallback onTap) {
      return Tooltip(
        message: tip,
        child: Semantics(
          button: true,
          selected: selected,
          label: tip,
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: 26,
              height: 22,
              color: selected
                  ? scheme.primary.withValues(alpha: 0.14)
                  : Colors.transparent,
              child: Icon(
                icon,
                size: Chrome.iconSmall,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.sm),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              half(AppIcons.chatCircle, 'Chat view', !onTerminal, onChat),
              half(
                AppIcons.terminal,
                'Terminal view',
                onTerminal,
                onTerminalView,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hides the Explorer and the side panel so the workbench has the window.
class _ZenButton extends ConsumerWidget {
  const _ZenButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zen = ref.watch(terminalMaximizedProvider);
    return IconButton(
      tooltip: zen ? 'Show the panels (Ctrl+\\)' : 'Focus mode (Ctrl+\\)',
      isSelected: zen,
      icon: const Icon(AppIcons.arrowsOutSimple, size: Chrome.icon),
      onPressed: () => ref.read(terminalMaximizedProvider.notifier).toggle(),
    );
  }
}
