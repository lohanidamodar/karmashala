import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/settings_controller.dart';
import '../domain/editor_settings.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Projects and files → In-app editor.
class EditorSection extends ConsumerWidget {
  const EditorSection({super.key});

  /// The pauses offered; a hand-edited value outside them is shown as well.
  static const autoSaveDelays = [250, 500, 1000, 2000, 5000, 10000];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wrap = ref.watch(
      settingsControllerProvider.select((s) => s.editorWordWrap),
    );
    final autoSave = ref.watch(
      settingsControllerProvider.select((s) => s.editorAutoSave),
    );
    final delay = ref.watch(
      settingsControllerProvider.select((s) => s.editorAutoSaveDelayMs),
    );
    final controller = ref.read(settingsControllerProvider.notifier);
    return SettingsSection(
      title: SettingsAnchor.editor.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSwitchRow(
            label: 'Wrap long lines in the editor',
            help: 'Soft-wrap instead of scrolling sideways.',
            value: wrap,
            onChanged: controller.setEditorWordWrap,
          ),
          SettingsRow(
            label: 'Auto save',
            help: 'A file changed on disk is never overwritten.',
            control: DropdownButtonFormField<EditorAutoSave>(
              initialValue: autoSave,
              isExpanded: true,
              items: [
                for (final mode in EditorAutoSave.values)
                  DropdownMenuItem(value: mode, child: Text(mode.label)),
              ],
              onChanged: (value) =>
                  value == null ? null : controller.setEditorAutoSave(value),
            ),
          ),
          if (autoSave == EditorAutoSave.afterDelay)
            SettingsRow(
              label: 'Auto save delay',
              help: 'How long typing has to pause before the file is written.',
              control: DropdownButtonFormField<int>(
                initialValue: delay,
                isExpanded: true,
                items: [
                  for (final ms in {...autoSaveDelays, delay}.toList()..sort())
                    DropdownMenuItem(
                      value: ms,
                      child: Text(_describeDelay(ms)),
                    ),
                ],
                onChanged: (value) => value == null
                    ? null
                    : controller.setEditorAutoSaveDelay(value),
              ),
            ),
        ],
      ),
    );
  }

  static String _describeDelay(int ms) => ms < 1000
      ? '$ms ms'
      : ms % 1000 == 0
      ? '${ms ~/ 1000} s'
      : '${(ms / 1000).toStringAsFixed(1)} s';
}

/// What the file-picker choice means on *this* desktop. A machine with no WSL
/// is not told about one, and only Windows has seen the host dialog fail.
String _blurbFor(bool inApp) {
  if (inApp) {
    return Platform.isWindows
        ? 'Karmashala lists folders itself. It can also browse a WSL '
              'distribution or a host over SSH, which the system dialog '
              'cannot.'
        : 'Karmashala lists folders itself. It can also browse a host over '
              'SSH, which the system dialog cannot.';
  }
  return Platform.isWindows
      ? "Your desktop's own dialog. On Windows it has been seen not to open at "
            'all in this app; if Browse stops responding, switch back.'
      : "Your desktop's own dialog. It cannot reach a host over SSH — a "
            'Browse pointed at one still uses Karmashala’s.';
}

/// Which dialog every "Browse…" opens, and whether browsers show hidden
/// entries.
///
/// The picker is a setting rather than a rule because Windows' own dialog was
/// measured failing to draw in this process, and macOS and Linux have not.
class FileBrowsingSection extends ConsumerWidget {
  const FileBrowsingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chosen = ref.watch(
      settingsControllerProvider.select((s) => s.useInAppFilePicker),
    );
    final hidden = ref.watch(
      settingsControllerProvider.select((s) => s.showHiddenFiles),
    );
    final controller = ref.read(settingsControllerProvider.notifier);
    final inApp = chosen ?? FilePickerChoice.platformDefault;

    return SettingsSection(
      title: SettingsAnchor.fileBrowsing.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // One board row: the choice as its control, what it means as its
          // help, and the way back to the default under it once chosen. Not
          // on a phone, where the answer is fixed ([FilePickerChoice.isPhone]).
          if (!FilePickerChoice.isPhone)
            SettingsRow(
              label: 'File picker',
              help: _blurbFor(inApp),
              controlMaxWidth: 280,
              control: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    icon: Icon(AppIcons.folderOpen, size: Chrome.icon),
                    label: Text('Karmashala'),
                  ),
                  ButtonSegment(
                    value: false,
                    icon: Icon(AppIcons.stack, size: Chrome.icon),
                    label: Text('System dialog'),
                  ),
                ],
                selected: {inApp},
                onSelectionChanged: (values) =>
                    controller.setUseInAppFilePicker(values.first),
                showSelectedIcon: false,
              ),
            ),
          if (chosen != null && !FilePickerChoice.isPhone)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => controller.setUseInAppFilePicker(null),
                  child: Text(
                    FilePickerChoice.platformDefault
                        ? 'Use what this platform defaults to (Karmashala)'
                        : 'Use what this platform defaults to (system dialog)',
                  ),
                ),
              ),
            ),
          SettingsSwitchRow(
            label: 'Show hidden files',
            help: 'Dot-files and hidden entries, in every file browser.',
            value: hidden,
            onChanged: controller.setShowHiddenFiles,
          ),
        ],
      ),
    );
  }
}
