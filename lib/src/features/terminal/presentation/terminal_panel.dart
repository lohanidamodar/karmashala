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
import '../application/terminal_sessions_controller.dart';
import '../data/terminal_instance.dart';
import '../domain/terminal_profile.dart';

/// The terminal panel: a tab bar of open terminals (each a real PTY) with a
/// button to open another, over the active terminal's xterm view.
///
/// Opening the panel with no tabs starts one with the user's default terminal
/// profile (PowerShell unless changed in Settings).
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
    ref
        .read(terminalSessionsControllerProvider.notifier)
        .open(profile, workingDirectory: _workingDirFor(profile));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(terminalSessionsControllerProvider);
    final controller = ref.read(terminalSessionsControllerProvider.notifier);
    final activeIndex = state.sessions.indexWhere(
      (s) => s.id == state.activeId,
    );

    return Material(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Column(
        children: [
          _TabBar(
            sessions: state.sessions,
            activeId: state.activeId,
            profiles: _profiles(),
            onSelect: controller.activate,
            onClose: controller.close,
            onOpen: _open,
            onHide: () => ref.read(terminalVisibleProvider.notifier).set(false),
          ),
          const Divider(height: 1),
          Expanded(
            child: state.sessions.isEmpty
                ? Center(
                    child: Text(
                      'Opening terminal…',
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                : IndexedStack(
                    index: activeIndex < 0 ? 0 : activeIndex,
                    children: [
                      for (final session in state.sessions)
                        TerminalView(
                          session.terminal,
                          controller: session.controller,
                          theme: _terminalTheme(theme),
                          textStyle: const TerminalStyle(
                            fontSize: 13,
                            fontFamily: kMonoFamily,
                          ),
                          padding: const EdgeInsets.all(Insets.sm),
                          autofocus: session.id == state.activeId,
                          // Desktop uses the physical keyboard; this also avoids
                          // xterm opening a software text-input client, which on
                          // Windows fails with "Could not set client, view ID is
                          // null" and blanks the terminal.
                          hardwareKeyboardOnly: true,
                          // Right-click → copy selection / paste.
                          onSecondaryTapDown: (details, _) => _terminalMenu(
                            context,
                            details.globalPosition,
                            session,
                          ),
                        ),
                    ],
                  ),
          ),
        ],
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
    }
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.sessions,
    required this.activeId,
    required this.profiles,
    required this.onSelect,
    required this.onClose,
    required this.onOpen,
    required this.onHide,
  });

  final List<TerminalInstance> sessions;
  final String? activeId;
  final List<TerminalProfile> profiles;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final ValueChanged<TerminalProfile> onOpen;
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
                for (final session in sessions)
                  _Tab(
                    title: session.title,
                    selected: session.id == activeId,
                    onTap: () => onSelect(session.id),
                    onClose: () => onClose(session.id),
                  ),
              ],
            ),
          ),
          PopupMenuButton<TerminalProfile>(
            tooltip: 'New terminal',
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
                  tooltip: 'Close terminal',
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
