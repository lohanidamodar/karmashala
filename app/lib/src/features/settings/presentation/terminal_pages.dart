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
import 'data_connection_notice.dart';
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
            help: 'Restart what was running. Agent panes wait for Start.',
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
            help: 'Exit codes, durations and command jumps. Not in cmd.',
            value: settings.shellIntegrationEnabled,
            onChanged: controller.setShellIntegrationEnabled,
          ),
          // Every local and WSL terminal runs in the server (slice 5a).
          const SessionHostStatusLine(),
          const DataConnectionNotice(),
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
        help: 'Ctrl+= larger, Ctrl+- smaller, Ctrl+0 default.',
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
          // Said under the row it is about, in its own tone, not as a loose
          // red line between rows.
          if (selected != null && value == null)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
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
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: Text(
                '${loaded.reason} Using the built-in colours.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (loaded is ThemeLoadOk && loaded.notes.isNotEmpty)
            SettingsNote(loaded.notes.join(' ')),
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
          const SettingsNote(
            'Shortcuts a focused terminal gives back to the app.',
          ),
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

/// One contested chord as a board row: the chord, what it does while the app
/// holds it (or that it goes to the shell), what the shell gives up for it,
/// and the switch.
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
    // The price is on screen only while it is being paid.
    final cost = claimed ? chord.shellCost : null;
    return MergeSemantics(
      child: SettingsRow(
        label: chord.label,
        helpWidget: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(claimed ? chord.does : 'Goes to the shell'),
            if (cost != null) Text('The shell loses $cost'),
          ],
        ),
        control: Switch(value: claimed, onChanged: onChanged),
      ),
    );
  }
}
