import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/theme/ui_text_scale.dart';
import '../../system/launcher_hotkey.dart';
import '../../system/native_status.dart';
import '../application/settings_controller.dart';
import '../domain/app_theme_mode.dart';
import 'native_setting_status_line.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Appearance: theme, UI text size, density.
class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    // The dropdown's value must be one of its items; snap a stored scale that
    // is not on the menu (an old file, a hand edit) to the nearest step.
    final scale = uiTextScaleOptions.reduce(
      (a, b) =>
          (a - settings.uiTextScale).abs() < (b - settings.uiTextScale).abs()
          ? a
          : b,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'APPEARANCE',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsRow(
                label: 'Theme',
                controlMaxWidth: 400,
                control: SegmentedButton<AppThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: AppThemeMode.system,
                      icon: Icon(AppIcons.circleHalf, size: Chrome.icon),
                      label: Text('System'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.light,
                      icon: Icon(AppIcons.sun, size: Chrome.icon),
                      label: Text('Light'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.dark,
                      icon: Icon(AppIcons.moon, size: Chrome.icon),
                      label: Text('Dark'),
                    ),
                  ],
                  selected: {settings.themeMode},
                  onSelectionChanged: (s) => controller.setThemeMode(s.first),
                ),
              ),
              SettingsRow(
                label: 'UI text size',
                help:
                    'Scales every label, menu, dialog and tooltip. The '
                    'terminal has its own font size under Terminal.',
                controlMaxWidth: 160,
                control: DropdownButtonFormField<double>(
                  initialValue: scale,
                  items: [
                    for (final option in uiTextScaleOptions)
                      DropdownMenuItem(
                        value: option,
                        child: Text('${(option * 100).round()}%'),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) controller.setUiTextScale(value);
                  },
                ),
              ),
              SettingsSwitchRow(
                label: 'Compact density',
                help: 'Denser lists and controls. Turn off for a roomier '
                    'layout.',
                value: settings.compactDensity,
                onChanged: controller.setCompactDensity,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Settings → System: OS integrations (awake, tray, login) and the global
/// launcher hotkey.
class SystemPage extends ConsumerWidget {
  const SystemPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'SYSTEM',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsSwitchRow(
                label: 'Keep system awake',
                help:
                    'Prevent the display and system from sleeping while '
                    'Karmashala is running.',
                value: settings.keepAwake,
                onChanged: controller.setKeepAwake,
              ),
              NativeSettingStatusLine(
                NativeSetting.keepAwake,
                enabled: settings.keepAwake,
              ),
              SettingsSwitchRow(
                label: 'Close to tray',
                help:
                    'Hide to the system tray when the window is closed '
                    'instead of quitting.',
                value: settings.closeToTray,
                onChanged: controller.setCloseToTray,
              ),
              NativeSettingStatusLine(
                NativeSetting.closeToTray,
                enabled: settings.closeToTray,
              ),
              SettingsSwitchRow(
                label: 'Start at login',
                help: 'Launch Karmashala automatically when you sign in.',
                value: settings.autoStart,
                onChanged: controller.setAutoStart,
              ),
              NativeSettingStatusLine(
                NativeSetting.autoStart,
                enabled: settings.autoStart,
              ),
            ],
          ),
        ),
        const LauncherHotkeySection(),
      ],
    );
  }
}

/// The global hotkey that summons the window from anywhere. Shows the current
/// combo with a Change button; recording only happens inside the dialog
/// the button opens, so it never captures stray keypresses on the settings page.
class LauncherHotkeySection extends ConsumerWidget {
  const LauncherHotkeySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final hotKey = decodeLauncherHotKey(settings.launcherHotkeyJson);
    final enabled = settings.launcherHotkeyEnabled;

    return SettingsSection(
      title: 'LAUNCHER HOTKEY',
      trailing: Switch(
        value: enabled,
        onChanged: controller.setLauncherHotkeyEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'A global shortcut that brings Karmashala forward from any app '
            'with quick open ready, and puts it away again when it is already '
            'in front.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.sm),
          Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    launcherHotKeyLabel(hotKey),
                    style: MonoStyles.label,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: enabled
                      ? () async {
                          final recorded = await showDialog<HotKey>(
                            context: context,
                            builder: (_) =>
                                _HotkeyRecorderDialog(initial: hotKey),
                          );
                          if (recorded != null) {
                            controller.setLauncherHotkey(
                              encodeLauncherHotKey(recorded),
                            );
                          }
                        }
                      : null,
                  icon: const Icon(AppIcons.pencilSimple, size: 15),
                  label: const Text('Change'),
                ),
              ],
            ),
          ),
          // A chord another application already holds registers as a failure
          // and nothing else; without this the switch says on and the shortcut
          // does nothing. Changing the chord resets the retry budget, so this
          // line is also the instruction for clearing it.
          NativeSettingStatusLine(
            NativeSetting.launcherHotkey,
            enabled: enabled,
          ),
        ],
      ),
    );
  }
}

/// A modal that records a single hotkey. The recorder is only active while this
/// dialog is open, so it can't swallow keypresses meant for the settings page.
class _HotkeyRecorderDialog extends StatefulWidget {
  const _HotkeyRecorderDialog({required this.initial});

  final HotKey initial;

  @override
  State<_HotkeyRecorderDialog> createState() => _HotkeyRecorderDialogState();
}

class _HotkeyRecorderDialogState extends State<_HotkeyRecorderDialog> {
  HotKey? _recorded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Set launcher hotkey'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Press the key combination you want, then Save.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Insets.md),
          HotKeyRecorder(
            initalHotKey: _recorded ?? widget.initial,
            onHotKeyRecorded: (hotKey) => setState(() => _recorded = hotKey),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_recorded ?? widget.initial),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
