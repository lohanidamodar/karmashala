import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/shell_shortcuts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../terminal/application/terminal_theme_controller.dart';
import 'package:karmashala_terminal_runtime/themes.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import '../application/settings_controller.dart';
import '../domain/settings.dart';
import 'session_host_status_line.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';
import '../../terminal/application/terminal_profiles.dart';

/// Settings → Terminal → Default terminal: the shell, and what comes back at
/// launch.
class DefaultTerminalSection extends ConsumerWidget {
  const DefaultTerminalSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final profiles = ref.watch(terminalProfilesProvider);
    final current = resolveTerminalProfile(
      settings.defaultTerminalProfileId,
      profiles,
    );
    return SettingsSection(
      title: SettingsAnchor.defaultTerminal.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsRow(
            label: 'Shell new terminals open with',
            control: DropdownButtonFormField<String>(
              initialValue: current.id,
              // Long profile labels otherwise overflow at large text.
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
            label: 'Resume running panes on launch',
            help:
                'Panes that had something running when the app last '
                'closed start again, in the tab that was in front. Other '
                'tabs, and any pane running an agent CLI, come back as '
                'history with a Start button — starting an agent would '
                're-run its conversation unasked.',
            value: settings.restoreLivePanes,
            onChanged: controller.setRestoreLivePanes,
          ),
        ],
      ),
    );
  }
}

/// Settings → Terminal → Shell integration & session host: the two switches
/// that change what a new pane can report, so they sit last.
class TerminalAdvancedSection extends ConsumerWidget {
  const TerminalAdvancedSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    return SettingsSection(
      title: SettingsAnchor.terminalAdvanced.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSwitchRow(
            label: 'Shell integration',
            help:
                'Mark where each command starts and ends, so the '
                'terminal can show exit codes and durations and jump '
                'between commands. PowerShell, and bash or zsh in a WSL pane; '
                'never cmd, which has no hook for a command’s end. Set up at launch — '
                'your profile is never modified — and applies to new '
                'terminals.',
            value: settings.shellIntegrationEnabled,
            onChanged: controller.setShellIntegrationEnabled,
          ),
          SettingsSwitchRow(
            label: 'Run local terminals in the session host',
            help:
                'A pane\'s shell is started by karmashala_host instead of '
                'by this app, so it survives a crash or a restart and '
                'reopening the pane resumes it where it left off. Applies '
                'to new terminals. Shell integration works here as it does '
                'in any other pane; a pane that resumes a session keeps the '
                'integration it was started with.',
            value: settings.hostBackedLocalPanes,
            onChanged: controller.setHostBackedLocalPanes,
          ),
          // Under the switch either way: it is what the decision needs.
          const SessionHostStatusLine(),
        ],
      ),
    );
  }
}

/// The terminal's font size — separate from the UI text scale on purpose.
class TerminalFontSection extends ConsumerWidget {
  const TerminalFontSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = ref.watch(
      settingsControllerProvider.select((s) => s.terminalFontSize),
    );
    final controller = ref.read(settingsControllerProvider.notifier);
    final isDefault = size == Settings.defaultTerminalFontSize;
    return SettingsSection(
      title: SettingsAnchor.terminalFont.heading,
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
            // Flexible, not fixed: the mono number grows with the text scale.
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

/// Import a terminal colour theme from Ghostty or Warp. The identity is
/// stored, not the colours, so editing the file is picked up.
class TerminalThemeSection extends ConsumerWidget {
  const TerminalThemeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(settingsControllerProvider.notifier);
    final selected = ref.watch(settingsControllerProvider).terminalThemeSource;
    final discovered = ref.watch(discoveredTerminalThemesProvider);
    final loaded = ref.watch(importedTerminalThemeProvider);

    // A vanished theme file would leave the dropdown on a value no item
    // carries, which makes it throw.
    final ids = discovered.map((t) => t.id).toSet();
    final value = selected != null && ids.contains(selected) ? selected : null;

    return SettingsSection(
      title: SettingsAnchor.terminalTheme.heading,
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
/// process inside it. Both defaults are a guess about how you work. Only
/// contested chords are listed — a terminal cannot encode `Ctrl+Shift+<letter>`.
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
      title: SettingsAnchor.terminalChords.heading,
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
    // The price is on screen only while it is being paid.
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
