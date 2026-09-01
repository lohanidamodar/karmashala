import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/shell_shortcuts.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../terminal/application/terminal_theme_controller.dart';
import '../../terminal/data/theme_discovery.dart';
import '../../terminal/domain/terminal_profile.dart';
import '../application/settings_controller.dart';
import '../domain/settings.dart';
import 'settings_row.dart';
import 'settings_section.dart';
import '../../terminal/application/terminal_profiles.dart';

/// Settings → Terminal: the default shell, the grid's own font size, imported
/// colour themes and the contested chords.
class TerminalPage extends ConsumerWidget {
  const TerminalPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final profiles = ref.watch(terminalProfilesProvider);
    final current = resolveTerminalProfile(
      settings.defaultTerminalProfileId,
      profiles,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'DEFAULT TERMINAL',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsRow(
                label: 'Shell new terminals open with',
                control: DropdownButtonFormField<String>(
                  initialValue: current.id,
                  // Long profile labels otherwise size the button past its
                  // box and overflow it by a hair at large text sizes.
                  isExpanded: true,
                  items: [
                    for (final profile in profiles)
                      DropdownMenuItem(
                        value: profile.id,
                        child: Text(profile.label),
                      ),
                  ],
                  onChanged: (id) {
                    if (id != null) controller.setDefaultTerminalProfile(id);
                  },
                ),
              ),
              SettingsSwitchRow(
                label: 'Shell integration',
                help:
                    'Mark where each command starts and ends, so the '
                    'terminal can show exit codes and durations and jump '
                    'between commands. PowerShell only. Set up at launch — '
                    'your profile is never modified — and applies to new '
                    'terminals.',
                value: settings.shellIntegrationEnabled,
                onChanged: controller.setShellIntegrationEnabled,
              ),
            ],
          ),
        ),
        const _TerminalFontSection(),
        const TerminalThemeSection(),
        const TerminalChordsSection(),
      ],
    );
  }
}

/// The terminal's own font size — deliberately separate from the UI text
/// scale: grid density and label legibility are different preferences.
class _TerminalFontSection extends ConsumerWidget {
  const _TerminalFontSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = ref.watch(
      settingsControllerProvider.select((s) => s.terminalFontSize),
    );
    final controller = ref.read(settingsControllerProvider.notifier);
    final isDefault = size == Settings.defaultTerminalFontSize;
    return SettingsSection(
      title: 'FONT',
      child: SettingsRow(
        label: 'Terminal font size',
        help:
            'In a focused terminal: Ctrl+= larger, Ctrl+- smaller, '
            'Ctrl+0 back to default.',
        controlMaxWidth: 220,
        control: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (!isDefault)
              IconButton(
                tooltip: 'Reset terminal font size',
                onPressed: controller.resetTerminalFontSize,
                icon: const Icon(
                  AppIcons.arrowCounterClockwise,
                  size: Chrome.icon,
                ),
              ),
            IconButton(
              tooltip: 'Smaller terminal font',
              onPressed: size > Settings.minTerminalFontSize
                  ? () => controller.adjustTerminalFontSize(-1)
                  : null,
              icon: const Icon(AppIcons.minusCircle, size: Chrome.icon),
            ),
            // Flexible, not a fixed box: the number is mono text and grows
            // with the UI text scale like everything else on the page.
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 30),
                child: Text(
                  size == size.roundToDouble()
                      ? '${size.round()}'
                      : size.toStringAsFixed(1),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: MonoStyles.label,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Larger terminal font',
              onPressed: size < Settings.maxTerminalFontSize
                  ? () => controller.adjustTerminalFontSize(1)
                  : null,
              icon: const Icon(AppIcons.plusCircle, size: Chrome.icon),
            ),
          ],
        ),
      ),
    );
  }
}

/// Import a terminal colour theme from Ghostty or Warp.
///
/// The stored value is the theme's identity, not its colours, so editing the
/// file is picked up. If it later disappears or breaks, the terminal keeps the
/// built-in theme and the reason is shown here rather than anywhere near the
/// terminal itself.
class TerminalThemeSection extends ConsumerWidget {
  const TerminalThemeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(settingsControllerProvider.notifier);
    final selected = ref.watch(settingsControllerProvider).terminalThemeSource;
    final discovered = ref.watch(discoveredTerminalThemesProvider);
    final loaded = ref.watch(importedTerminalThemeProvider);

    // A stored theme whose file has since gone would leave the dropdown with a
    // value none of its items carry, which makes it throw and flash red.
    final ids = discovered.map((t) => t.id).toSet();
    final value = selected != null && ids.contains(selected) ? selected : null;

    return SettingsSection(
      title: 'TERMINAL THEME',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsRow(
            label: 'Colours',
            help: discovered.isEmpty
                ? 'No Ghostty or Warp themes found on this machine.'
                : null,
            control: DropdownButtonFormField<String?>(
              isExpanded: true,
              initialValue: value,
              items: [
                const DropdownMenuItem(value: null, child: Text('Built-in')),
                for (final t in discovered)
                  DropdownMenuItem(
                    value: t.id,
                    child: Text('${t.name}  ·  ${t.format.name}'),
                  ),
              ],
              onChanged: (id) => controller.setTerminalThemeSource(id),
            ),
          ),
          if (selected != null && value == null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: Text(
                'The saved theme is no longer where it was; using the built-in '
                'colours.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (loaded is ThemeLoadError)
            Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: Text(
                '${loaded.reason} Using the built-in colours.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (loaded is ThemeLoadOk && loaded.notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: Text(
                loaded.notes.join(' '),
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

/// Who gets a keystroke when a terminal pane has focus: Karmashala, or the
/// process inside the pane.
///
/// This exists because the honest answer is "it depends on how you work".
/// `Ctrl+B` is the tmux prefix, and taking it from someone who lives in tmux
/// breaks every window, pane and copy-mode command they have; `Ctrl+K` is
/// readline's kill-line, and quick open is the chord this app is used through.
/// Both defaults are a guess about the user, so both are switches.
///
/// Only the contested chords are listed. A terminal cannot encode
/// `Ctrl+Shift+<letter>` at all, so those take nothing from the shell however
/// they are set and a switch for them would be a switch that does nothing.
class TerminalChordsSection extends ConsumerWidget {
  const TerminalChordsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final overrides = ref.watch(
      settingsControllerProvider.select((s) => s.terminalChordOverrides),
    );
    final controller = ref.read(settingsControllerProvider.notifier);
    final contested = shellChords.where((c) => c.contested).toList();

    return SettingsSection(
      title: 'TERMINAL CHORDS',
      trailing: overrides.isEmpty
          ? null
          : TextButton(
              onPressed: controller.resetTerminalChordOverrides,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: theme.textTheme.labelSmall,
              ),
              child: const Text('Reset to defaults'),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'A focused terminal pane sees every key first. These chords are '
            'taken back for the app; switch one off and it reaches the shell '
            'instead. Chords with Shift are never in question — a terminal '
            'cannot encode them.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.sm),
          for (final chord in contested)
            _ChordRow(
              chord: chord,
              claimed: chord.claimedByApp(overrides),
              onChanged: (value) =>
                  controller.setTerminalChordClaimed(chord.label, value),
            ),
        ],
      ),
    );
  }
}

class _ChordRow extends StatelessWidget {
  const _ChordRow({
    required this.chord,
    required this.claimed,
    required this.onChanged,
  });

  final ShellChord chord;
  final bool claimed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The price is only on screen while it is being paid. Saying what Ctrl+K
    // costs a shell that is not being asked to give it up is noise.
    final cost = claimed ? chord.shellCost : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(chord.label, style: MonoStyles.body),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    claimed ? chord.does : 'Goes to the shell',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: claimed
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (cost != null)
                  Text(
                    'The shell loses $cost',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 0,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
              ],
            ),
          ),
          Switch(value: claimed, onChanged: onChanged),
        ],
      ),
    );
  }
}
