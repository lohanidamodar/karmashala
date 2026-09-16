import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/settings_controller.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Editor & files → In-app editor.
class EditorSection extends ConsumerWidget {
  const EditorSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wrap = ref.watch(
      settingsControllerProvider.select((s) => s.editorWordWrap),
    );
    final controller = ref.read(settingsControllerProvider.notifier);
    return SettingsSection(
      title: SettingsAnchor.editor.heading,
      child: SettingsSwitchRow(
        label: 'Wrap long lines in the editor',
        help:
            'Soft-wrap instead of scrolling sideways. Line numbers are hidden '
            'while wrapping, because the gutter cannot line up with a wrapped '
            'line.',
        value: wrap,
        onChanged: controller.setEditorWordWrap,
      ),
    );
  }
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
    final theme = Theme.of(context);
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
          Text('File picker', style: theme.textTheme.bodyMedium),
          const SizedBox(height: Insets.xs),
          SegmentedButton<bool>(
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
          const SizedBox(height: Insets.sm),
          Text(
            _blurbFor(inApp),
            style: theme.textTheme.bodySmall?.copyWith(
              color: SemanticColors.of(context).neutral,
            ),
          ),
          if (chosen != null) ...[
            const SizedBox(height: Insets.xs),
            Align(
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
          ],
          const SizedBox(height: Insets.sm),
          SettingsSwitchRow(
            label: 'Show hidden files',
            help:
                'Dot-files and hidden entries, in every file browser — the '
                'picker, the SSH browser and a device’s. The same switch sits '
                'inside each browser.',
            value: hidden,
            onChanged: controller.setShowHiddenFiles,
          ),
        ],
      ),
    );
  }
}
