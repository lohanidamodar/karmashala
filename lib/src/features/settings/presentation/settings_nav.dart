
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';

/// The sections of the settings screen — the master list of the master-detail.
///
/// An enum so a caller can deep-link (`openSettingsTab(ref,
/// section: SettingsSectionId.agents)`) without knowing how the page lays
/// itself out. Keywords feed the nav's filter box, so "font" finds Terminal
/// and "zoom" finds Appearance.
enum SettingsSectionId {
  appearance('Appearance', AppIcons.circleHalf, [
    'theme',
    'dark',
    'light',
    'text size',
    'zoom',
    'scale',
    'density',
    'compact',
  ]),
  system('System', AppIcons.power, [
    'tray',
    'startup',
    'start at login',
    'keep awake',
    'sleep',
    'hotkey',
    'launcher',
  ]),
  terminal('Terminal', AppIcons.terminal, [
    'shell',
    'font',
    'size',
    'theme',
    'colors',
    'chords',
    'keys',
    'integration',
  ]),
  // Its own row rather than a block under Terminal: the library is a list the
  // user curates, like Notes and the SSH hosts, and the complaint that put it
  // here was that it "doesn't live anywhere" — which a section three scrolls
  // down inside Terminal would not answer. Next to Terminal, though, because a
  // snippet is a line typed into one.
  snippets('Snippets', AppIcons.bookBookmark, [
    'snippet',
    'snippets',
    'command',
    'commands',
    'saved command',
    'library',
  ]),
  tools('Tools', AppIcons.code, [
    'editor',
    'vs code',
    'terminal app',
    'resume',
    'mcp',
    'bridge',
    'agent tools',
    'tool list',
    'browser consent',
  ]),
  agents('Agents', AppIcons.robot, [
    'default agent',
    'default model',
    'model',
    'opus',
    'sonnet',
    'claude',
    'codex',
    'accounts',
    'usage',
    'limits',
  ]),
  permissions('Permissions', AppIcons.handTap, [
    'ask',
    'bypass',
    'accept edits',
    'sessions',
  ]),
  // Beside Permissions, because the mode an automation runs under is the rule
  // that decides whether it may run at all: a mode that stops to ask is
  // refused on a trigger with nobody there to answer.
  automations('Automations', AppIcons.clockCounterClockwise, [
    'automation',
    'automations',
    'schedule',
    'scheduled',
    'cron',
    'nightly',
    'unattended',
    'afk',
    'project check',
    'checks',
    'verification',
  ]),
  // Beside Environments rather than under Agents: what it configures is a
  // *checkout*, and where a setup command runs is decided by that checkout's
  // environment.
  worktrees('Worktrees', AppIcons.gitBranch, [
    'worktree',
    'worktrees',
    'setup',
    'post create',
    'pub get',
    'copy',
    'gitignored',
    'dart_tool',
    'node_modules',
  ]),
  environments('Environments', AppIcons.terminalWindow, [
    'wsl',
    'windows',
    'discover',
    'installations',
    'flutter',
    'flutter sdk',
    'sdk',
    'dart',
  ]),
  environmentVariables('Environment variables', AppIcons.code, [
    'env',
    'env var',
    'environment variable',
    'secret',
    'secrets',
    'token',
    'api key',
    'credential',
  ]),
  ssh('SSH', AppIcons.globe, ['hosts', 'known hosts', 'keys', 'remote build']),
  remote('Remote access', AppIcons.deviceMobile, [
    'companion',
    'phone',
    'pairing',
    'relay',
    'devices',
  ]),
  notes('Notes', AppIcons.note, [
    'note',
    'notes',
    'idea',
    'ideas',
    'save for later',
    'later',
  ]),
  diagnostics('Diagnostics', AppIcons.listMagnifyingGlass, [
    'logs',
    'log file',
    'debug',
    'debug mode',
    'verbose',
    'troubleshoot',
    'report',
  ]);

  const SettingsSectionId(this.label, this.icon, this.keywords);

  final String label;
  final IconData icon;
  final List<String> keywords;

  /// Whether the section should stay listed while [query] is in the filter.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (label.toLowerCase().contains(q)) return true;
    return keywords.any((k) => k.contains(q));
  }
}

/// The compact section list on the left of the settings screen (and the whole
/// screen at phone widths): a filter box over one row per section.
///
/// Keyboard: the rows are ordinary focus stops, and while any of them has
/// focus, Up/Down move the *selection* — the content pane follows immediately,
/// the way a settings sidebar is expected to behave. The filter field keeps
/// its arrow keys for the caret because the handler wraps only the list.
class SettingsNav extends StatefulWidget {
  const SettingsNav({
    required this.selected,
    required this.onSelect,
    super.key,
  });

  /// The section whose row is highlighted, or null when none is (the phone
  /// list before a section is opened).
  final SettingsSectionId? selected;

  final ValueChanged<SettingsSectionId> onSelect;

  @override
  State<SettingsNav> createState() => _SettingsNavState();
}

class _SettingsNavState extends State<SettingsNav> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  List<SettingsSectionId> get _visible => [
    for (final section in SettingsSectionId.values)
      if (section.matches(_filter.text)) section,
  ];

  KeyEventResult _onListKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final sections = _visible;
    if (sections.isEmpty) return KeyEventResult.ignored;
    final step = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => 1,
      LogicalKeyboardKey.arrowUp => -1,
      _ => 0,
    };
    if (step == 0) return KeyEventResult.ignored;
    final index = widget.selected == null
        ? -1
        : sections.indexOf(widget.selected!);
    final next = index == -1
        ? (step > 0 ? 0 : sections.length - 1)
        : (index + step).clamp(0, sections.length - 1);
    if (next != index) widget.onSelect(sections[next]);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final sections = _visible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.sm,
            Insets.sm,
            Insets.sm,
            Insets.xs,
          ),
          child: TextField(
            controller: _filter,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Filter settings',
              prefixIcon: Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
              prefixIconConstraints: BoxConstraints(minWidth: 30),
            ),
          ),
        ),
        Expanded(
          child: Focus(
            // A key handler, not a focus stop: it hears the arrows bubbling up
            // from whichever row has focus.
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onListKey,
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.xs,
                vertical: Insets.xs,
              ),
              children: [
                for (final section in sections)
                  _NavRow(
                    section: section,
                    selected: section == widget.selected,
                    onTap: () => widget.onSelect(section),
                  ),
                if (sections.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Insets.md),
                    child: Text(
                      'Nothing matches.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final SettingsSectionId section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: section.label,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: Chrome.row + 2),
            padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Icon(section.icon, size: Chrome.icon, color: color),
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: ExcludeSemantics(
                    child: Text(
                      section.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: selected ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
