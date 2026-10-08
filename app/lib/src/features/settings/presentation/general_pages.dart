import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/theme.dart';
import '../../overview/application/overview_prefs.dart';
import '../../system/launcher_hotkey.dart';
import '../../system/native_status.dart';
import '../application/settings_controller.dart';
import '../domain/app_theme_mode.dart';
import 'native_setting_status_line.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Appearance → Theme & text: theme, UI text size, density.
class ThemeTextSection extends ConsumerWidget {
  const ThemeTextSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    // The dropdown's value must be one of its items; snap to the nearest step.
    final scale = uiTextScaleOptions.reduce(
      (a, b) =>
          (a - settings.uiTextScale).abs() < (b - settings.uiTextScale).abs()
          ? a
          : b,
    );
    return SettingsSection(
      title: SettingsAnchor.themeText.heading,
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
            help: 'All app text. The terminal has its own size.',
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
          SettingsRow(
            label: 'Accent',
            help:
                'Selection, focus and the primary action. Status colours '
                'stay the same.',
            // Five swatches at their own width, not spread across a pane.
            stackedFit: SettingsControlFit.start,
            control: _AccentSwatches(
              selected: settings.accent,
              onSelected: controller.setAccent,
            ),
          ),
          SettingsSwitchRow(
            label: 'Lines between regions',
            help: 'Off, regions are told apart by tone alone.',
            value: settings.separation == SurfaceSeparation.borders,
            onChanged: (on) => controller.setSeparation(
              on ? SurfaceSeparation.borders : SurfaceSeparation.tones,
            ),
          ),
          // A pointer-only choice: a touch device's density is its own.
          if (UiDensity.of(context).isTouch)
            const SettingsRow(
              label: 'Density',
              control: Text('Touch (set by this device)'),
            )
          else
            SettingsSwitchRow(
              label: 'Compact density',
              help: 'Denser lists and controls. Turn off for a roomier layout.',
              value: settings.compactDensity,
              onChanged: controller.setCompactDensity,
            ),
        ],
      ),
    );
  }
}

/// One swatch per accent; the picked one wears a ring. Each says its name, so
/// the choice is never made by colour alone. One tab stop, like a radio group:
/// the arrows move the choice.
class _AccentSwatches extends StatelessWidget {
  const _AccentSwatches({required this.selected, required this.onSelected});

  final AppAccent selected;
  final ValueChanged<AppAccent> onSelected;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final step = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowRight || LogicalKeyboardKey.arrowDown => 1,
      LogicalKeyboardKey.arrowLeft || LogicalKeyboardKey.arrowUp => -1,
      _ => 0,
    };
    if (step == 0) return KeyEventResult.ignored;
    const all = AppAccent.values;
    onSelected(all[(selected.index + step) % all.length]);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final ring = theme.colorScheme.onSurface;
    return Focus(
      onKeyEvent: _onKey,
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Semantics(
            label: 'Accent: ${selected.label}',
            hint: 'Arrow keys change it',
            child: Container(
              padding: const EdgeInsets.all(Insets.xs),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(
                  color: focused
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                ),
              ),
              child: Wrap(
                spacing: Insets.sm,
                children: [
                  for (final accent in AppAccent.values)
                    Tooltip(
                      message: accent.label,
                      child: InkResponse(
                        onTap: () => onSelected(accent),
                        canRequestFocus: false,
                        radius: 16,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: accent.forBrightness(brightness),
                            border: accent == selected
                                ? Border.all(color: ring, width: 2)
                                : null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Settings → General → Startup & window: how the app starts, closes and
/// keeps the machine awake.
class StartupSection extends ConsumerWidget {
  const StartupSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    return SettingsSection(
      title: SettingsAnchor.startup.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
          SettingsSwitchRow(
            label: 'Ask before quitting with sessions running',
            help: 'Off, quitting reuses your last answers.',
            value: settings.quitAsks,
            onChanged: controller.setQuitAsks,
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
            label: 'Keep system awake',
            value: settings.keepAwake,
            onChanged: controller.setKeepAwake,
          ),
          NativeSettingStatusLine(
            NativeSetting.keepAwake,
            enabled: settings.keepAwake,
          ),
          SettingsSwitchRow(
            label: 'Bring sessions agents start to the front',
            help:
                'Off, a session another session starts opens behind the tab '
                'you are in, marked new.',
            value: settings.bringAgentSessionsToFront,
            onChanged: controller.setBringAgentSessionsToFront,
          ),
        ],
      ),
    );
  }
}

/// Settings → General → Session view: which face an agent session opens on,
/// and whether resuming or starting one moves you. Shown on every client — a
/// phone is where the first answer differs.
class SessionViewSection extends ConsumerWidget {
  const SessionViewSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsSection(
      title: SettingsAnchor.sessionView.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSwitchRow(
            label: 'Open agent sessions in chat view',
            help:
                'Terminal sessions show their chat first; the Terminal '
                'toggle is still one click away.',
            value: ref.watch(sessionsOpenInChatProvider),
            onChanged: ref
                .read(settingsControllerProvider.notifier)
                .setOpenSessionsInChat,
          ),
          // Kept on this device, in the Agent dashboard's own file.
          SettingsSwitchRow(
            key: const ValueKey('settings-launch-in-background'),
            label: 'Resume and start sessions in the background',
            help:
                'From the command palette, the Agent dashboard or a '
                "session's menu, no tab opens and you stay where you are. "
                'Open and Open tab still open one. On this device.',
            value: ref.watch(launchInBackgroundProvider),
            onChanged: ref
                .read(overviewPrefsProvider.notifier)
                .setLaunchInBackground,
          ),
        ],
      ),
    );
  }
}

/// The global hotkey that summons the window. Recording happens only inside
/// the Change dialog, so it never captures the settings page's keypresses.
class LauncherHotkeySection extends ConsumerWidget {
  const LauncherHotkeySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final hotKey = decodeLauncherHotKey(settings.launcherHotkeyJson);
    final enabled = settings.launcherHotkeyEnabled;

    Future<void> change() async {
      final recorded = await showDialog<HotKey>(
        context: context,
        builder: (_) => _HotkeyRecorderDialog(initial: hotKey),
      );
      if (recorded != null) {
        controller.setLauncherHotkey(encodeLauncherHotKey(recorded));
      }
    }

    // Board rows: the switch, then the chord as the row's value with Change
    // beside it — dimmed, not hidden, while the hotkey is off.
    return SettingsSection(
      title: SettingsAnchor.launcherHotkey.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSwitchRow(
            label: 'Use the launcher hotkey',
            help: 'Brings Karmashala forward from any app, with quick open.',
            value: enabled,
            onChanged: controller.setLauncherHotkeyEnabled,
          ),
          Opacity(
            opacity: enabled ? 1 : 0.5,
            child: SettingsRow(
              label: 'Hotkey',
              stackedFit: SettingsControlFit.start,
              control: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: SettingsValue(
                      label: launcherHotKeyLabel(hotKey),
                      mono: true,
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  OutlinedButton.icon(
                    onPressed: enabled ? change : null,
                    icon: const Icon(AppIcons.pencilSimple),
                    label: const Text('Change'),
                  ),
                ],
              ),
            ),
          ),
          // A chord another app holds only fails; changing it resets retries.
          NativeSettingStatusLine(
            NativeSetting.launcherHotkey,
            enabled: enabled,
          ),
        ],
      ),
    );
  }
}

/// A modal that records a single hotkey, active only while it is open.
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
