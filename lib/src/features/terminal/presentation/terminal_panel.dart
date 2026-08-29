import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environments_controller.dart';
import '../../environments/domain/environment_kind.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../application/terminal_search_controller.dart';
import '../application/terminal_sessions_controller.dart';
import '../data/terminal_instance.dart';
import '../domain/pane_layout.dart';
import '../domain/terminal_profile.dart';
import 'pane_layout_view.dart';
import 'terminal_search_bar.dart';

/// The terminal panel: a bar of tabs, each holding a tree of split panes, over
/// the active tab's panes.
///
/// Inactive tabs stay alive inside an [IndexedStack], which paints only its
/// active child — hidden tabs cost VT parsing but no painting, which is the
/// property Loop 26's performance work depends on.
class TerminalPanel extends ConsumerStatefulWidget {
  const TerminalPanel({super.key});

  @override
  ConsumerState<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends ConsumerState<TerminalPanel> {
  @override
  void initState() {
    super.initState();
    // Ensure there is always at least one terminal when the panel is shown.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(terminalSessionsControllerProvider).isEmpty) {
        _open(_defaultProfile());
      }
    });
  }

  TerminalSessionsController get _sessions =>
      ref.read(terminalSessionsControllerProvider.notifier);

  List<TerminalProfile> _profiles() =>
      terminalProfilesFor(ref.read(environmentsControllerProvider));

  TerminalProfile _defaultProfile() {
    final id = ref.read(settingsControllerProvider).defaultTerminalProfileId;
    return resolveTerminalProfile(id, _profiles());
  }

  /// The working directory a new terminal should start in, derived from the
  /// selected repository when it is compatible with the chosen shell.
  String? _workingDirFor(TerminalProfile profile) {
    final repoId = ref.read(selectedRepositoryIdProvider);
    if (repoId == null) return null;
    final repo = ref.read(repositoryDaoProvider).getById(repoId);
    if (repo == null) return null;
    final env = ref
        .read(executionEnvironmentDaoProvider)
        .getById(repo.path.environmentId);
    final repoIsWindows = env?.kind == EnvironmentKind.windowsNative;
    if (profile.shell == TerminalShell.wsl) return repo.path.path;
    return repoIsWindows ? repo.path.path : null;
  }

  void _open(TerminalProfile profile) {
    _sessions.openTab(profile, workingDirectory: _workingDirFor(profile));
  }

  void _split(SplitAxis axis, [TerminalProfile? profile]) {
    final chosen = profile ?? _defaultProfile();
    _sessions.splitPane(axis, chosen, workingDirectory: _workingDirFor(chosen));
  }

  void _closeFocusedPane() {
    final tab = ref.read(terminalSessionsControllerProvider).activeTab;
    if (tab != null) _sessions.closePane(tab.focusedPaneId);
  }

  void _openSearch() {
    final tab = ref.read(terminalSessionsControllerProvider).activeTab;
    if (tab == null) return;
    ref.read(terminalSearchControllerProvider.notifier).open(tab.focusedPaneId);
  }

  /// Terminal-wide shortcuts, handled through `TerminalView.onKeyEvent`, which
  /// the widget consults *before* its own shortcut manager and before
  /// `Terminal.keyInput`.
  ///
  /// All are `Ctrl+Shift+*` because `Ctrl+D`, `Ctrl+E`, `Ctrl+F` and `Ctrl+W`
  /// are live control characters a shell expects to receive.
  KeyEventResult _onPaneKey(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final shift = keyboard.isShiftPressed;
    final alt = keyboard.isAltPressed;

    void Function()? action;
    if (shift && !alt) {
      if (key == LogicalKeyboardKey.keyD) {
        action = () => _split(SplitAxis.horizontal);
      } else if (key == LogicalKeyboardKey.keyE) {
        action = () => _split(SplitAxis.vertical);
      } else if (key == LogicalKeyboardKey.keyW) {
        action = _closeFocusedPane;
      } else if (key == LogicalKeyboardKey.keyF) {
        action = _openSearch;
      } else if (key == LogicalKeyboardKey.keyT) {
        action = () => _open(_defaultProfile());
      }
    } else if (alt && !shift) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        action = () => _sessions.movePaneFocus(PaneDirection.left);
      } else if (key == LogicalKeyboardKey.arrowRight) {
        action = () => _sessions.movePaneFocus(PaneDirection.right);
      } else if (key == LogicalKeyboardKey.arrowUp) {
        action = () => _sessions.movePaneFocus(PaneDirection.up);
      } else if (key == LogicalKeyboardKey.arrowDown) {
        action = () => _sessions.movePaneFocus(PaneDirection.down);
      }
    } else if (!shift && !alt) {
      if (key == LogicalKeyboardKey.pageUp) {
        action = _sessions.previousTab;
      } else if (key == LogicalKeyboardKey.pageDown) {
        action = _sessions.nextTab;
      }
    }

    if (action == null) return KeyEventResult.ignored;
    // Act once, on the down event, but swallow the matching up/repeat too so a
    // consumed combo cannot leak a character through xterm's fallback.
    if (event is KeyDownEvent) action();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(terminalSessionsControllerProvider);
    final search = ref.watch(terminalSearchControllerProvider);
    final activeIndex = state.tabs.indexWhere((t) => t.id == state.activeTabId);

    return Material(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Column(
        children: [
          _TabBar(
            tabs: state.tabs,
            activeTabId: state.activeTabId,
            titleFor: _sessions.titleForTab,
            profiles: _profiles(),
            onSelect: _sessions.activateTab,
            onClose: _sessions.closeTab,
            onOpen: _open,
            onSplit: _split,
            onFind: _openSearch,
            maximized: ref.watch(terminalMaximizedProvider),
            onToggleMaximize: () =>
                ref.read(terminalMaximizedProvider.notifier).toggle(),
            onHide: () => ref.read(terminalVisibleProvider.notifier).set(false),
          ),
          const Divider(height: 1),
          if (search.visible) const TerminalSearchBar(),
          Expanded(
            child: state.tabs.isEmpty
                ? Center(
                    child: Text(
                      'Opening terminal…',
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                : IndexedStack(
                    index: activeIndex < 0 ? 0 : activeIndex,
                    children: [
                      for (final tab in state.tabs)
                        PaneLayoutView(
                          layout: tab.layout,
                          onResize: (splitId, index, delta) =>
                              _resize(tab, splitId, index, delta),
                          paneBuilder: (paneId) => _buildPane(
                            paneId,
                            focused:
                                paneId == tab.focusedPaneId &&
                                tab.id == state.activeTabId,
                            showFocusRing: tab.layout.panes.length > 1,
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// Turns a pixel drag into a share of the split's own extent.
  void _resize(TerminalTab tab, String splitId, int index, double delta) {
    final box = context.findRenderObject() as RenderBox?;
    final extent = box == null ? 0.0 : box.size.longestSide;
    if (extent <= 0) return;
    _sessions.resizePane(tab.id, splitId, index, delta / extent);
  }

  Widget _buildPane(
    String paneId, {
    required bool focused,
    required bool showFocusRing,
  }) {
    final theme = Theme.of(context);
    final instance = _sessions.instanceFor(paneId);
    if (instance == null) return const SizedBox.shrink();

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) => _sessions.focusPane(paneId),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: showFocusRing
              ? Border.all(
                  color: focused
                      ? theme.colorScheme.tertiary
                      : Colors.transparent,
                )
              : null,
        ),
        child: TerminalView(
          instance.terminal,
          controller: instance.controller,
          focusNode: instance.focusNode,
          scrollController: instance.scrollController,
          theme: _terminalTheme(theme),
          textStyle: const TerminalStyle(fontSize: 13, fontFamily: kMonoFamily),
          padding: const EdgeInsets.all(Insets.sm),
          autofocus: focused,
          // Desktop uses the physical keyboard; this also avoids xterm opening
          // a software text-input client, which on Windows fails with "Could
          // not set client, view ID is null" and blanks the terminal.
          hardwareKeyboardOnly: true,
          onKeyEvent: _onPaneKey,
          // Right-click → copy selection / paste.
          onSecondaryTapDown: (details, _) =>
              _terminalMenu(context, details.globalPosition, instance),
        ),
      ),
    );
  }

  Future<void> _terminalMenu(
    BuildContext context,
    Offset position,
    TerminalInstance session,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selection = session.controller.selection;
    final hasSelection = selection != null;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'copy',
          enabled: hasSelection,
          child: const Text('Copy'),
        ),
        const PopupMenuItem(value: 'paste', child: Text('Paste')),
        const PopupMenuItem(value: 'find', child: Text('Find…')),
      ],
    );
    switch (choice) {
      case 'copy':
        if (selection != null) {
          final text = session.terminal.buffer.getText(selection);
          await Clipboard.setData(ClipboardData(text: text));
        }
      case 'paste':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text;
        if (text != null && text.isNotEmpty) session.terminal.paste(text);
      case 'find':
        _openSearch();
    }
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.activeTabId,
    required this.titleFor,
    required this.profiles,
    required this.onSelect,
    required this.onClose,
    required this.onOpen,
    required this.onSplit,
    required this.onFind,
    required this.maximized,
    required this.onToggleMaximize,
    required this.onHide,
  });

  final List<TerminalTab> tabs;
  final String? activeTabId;
  final String Function(String tabId) titleFor;
  final List<TerminalProfile> profiles;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final ValueChanged<TerminalProfile> onOpen;
  final void Function(SplitAxis axis) onSplit;
  final VoidCallback onFind;
  final bool maximized;
  final VoidCallback onToggleMaximize;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          const SizedBox(width: Insets.sm),
          Icon(AppIcons.terminal, size: 16, color: theme.colorScheme.tertiary),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final tab in tabs)
                  _Tab(
                    title: titleFor(tab.id),
                    selected: tab.id == activeTabId,
                    onTap: () => onSelect(tab.id),
                    onClose: () => onClose(tab.id),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Find in scrollback (Ctrl+Shift+F)',
            icon: const Icon(AppIcons.magnifyingGlass, size: 16),
            onPressed: tabs.isEmpty ? null : onFind,
          ),
          IconButton(
            tooltip: 'Split right (Ctrl+Shift+D)',
            icon: const Icon(AppIcons.sidebarSimple, size: 16),
            onPressed: tabs.isEmpty
                ? null
                : () => onSplit(SplitAxis.horizontal),
          ),
          IconButton(
            tooltip: 'Split down (Ctrl+Shift+E)',
            icon: const RotatedBox(
              quarterTurns: 1,
              child: Icon(AppIcons.sidebarSimple, size: 16),
            ),
            onPressed: tabs.isEmpty ? null : () => onSplit(SplitAxis.vertical),
          ),
          PopupMenuButton<TerminalProfile>(
            tooltip: 'New terminal tab',
            icon: const Icon(AppIcons.plus, size: 18),
            onSelected: onOpen,
            itemBuilder: (context) => [
              for (final profile in profiles)
                PopupMenuItem(
                  value: profile,
                  height: 32,
                  child: Row(
                    children: [
                      const Icon(AppIcons.terminal, size: 16),
                      const SizedBox(width: 10),
                      Text(profile.label),
                    ],
                  ),
                ),
            ],
          ),
          IconButton(
            tooltip: maximized ? 'Restore terminal' : 'Maximize terminal',
            isSelected: maximized,
            icon: const Icon(AppIcons.arrowsOutSimple, size: 18),
            onPressed: onToggleMaximize,
          ),
          IconButton(
            tooltip: 'Hide terminal (Ctrl+`)',
            icon: const Icon(AppIcons.x, size: 18),
            onPressed: onHide,
          ),
          const SizedBox(width: Insets.xs),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.title,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      child: Material(
        color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.only(left: Insets.sm, right: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 2),
                IconButton(
                  tooltip: 'Close tab',
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(AppIcons.x),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

TerminalTheme _terminalTheme(ThemeData theme) {
  // Keep xterm's well-tuned 16-colour palette; only align the background and
  // foreground with the app surface so the panel reads as one piece.
  final scheme = theme.colorScheme;
  return TerminalThemes.defaultTheme.copyWith(
    background: scheme.surfaceContainerLowest,
    foreground: scheme.onSurface,
    cursor: scheme.tertiary,
  );
}

extension on TerminalTheme {
  TerminalTheme copyWith({
    Color? background,
    Color? foreground,
    Color? cursor,
  }) {
    return TerminalTheme(
      cursor: cursor ?? this.cursor,
      selection: selection,
      foreground: foreground ?? this.foreground,
      background: background ?? this.background,
      black: black,
      red: red,
      green: green,
      yellow: yellow,
      blue: blue,
      magenta: magenta,
      cyan: cyan,
      white: white,
      brightBlack: brightBlack,
      brightRed: brightRed,
      brightGreen: brightGreen,
      brightYellow: brightYellow,
      brightBlue: brightBlue,
      brightMagenta: brightMagenta,
      brightCyan: brightCyan,
      brightWhite: brightWhite,
      searchHitBackground: searchHitBackground,
      searchHitBackgroundCurrent: searchHitBackgroundCurrent,
      searchHitForeground: searchHitForeground,
    );
  }
}
