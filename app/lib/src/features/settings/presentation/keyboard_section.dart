import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/keymap_controller.dart';
import '../../../app/shell/shell_shortcuts.dart';
import '../../editor/application/editor_tab_actions.dart';
import 'settings_catalog.dart';
import 'settings_notice.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Keyboard: every binding in force, read from the table
/// the keys themselves run on, so this list cannot drift from what they do.
///
/// Drawn as the board draws a keymap: one row per binding — what it does as
/// the label, the command under it, the chord as the row's value in the
/// ledger hand — so it reads like every other settings list, and a narrow
/// page drops the chord under its label like any other row.
class KeyboardSection extends ConsumerWidget {
  const KeyboardSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(keymapProvider);
    final chords = [...shellChords]
      ..sort((a, b) => a.command.compareTo(b.command));
    final path = status.path;

    return SettingsSection(
      title: SettingsAnchor.keyboard.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (path == null)
            const SettingsNote('The app’s own keys.')
          else
            SettingsRow(
              label: 'Keymap',
              help: 'Rebind keys in $path.',
              control: TextButton(
                key: const ValueKey('keymap-edit'),
                onPressed: () async {
                  final file = await ref
                      .read(keymapProvider.notifier)
                      .ensureFile();
                  if (file != null) {
                    ref.read(editorTabActionsProvider).open(file.path);
                  }
                },
                child: const Text('Edit keymap.json'),
              ),
            ),
          if (status.problems.isNotEmpty)
            SettingsNote(
              'keymap.json has problems.',
              child: SettingsNotice(
                tone: SettingsNoticeTone.attention,
                message: 'keymap.json is not in use; the last good one is.',
                detail: status.problems.join('\n'),
              ),
            ),
          for (final chord in chords)
            SettingsRow(
              label: chord.does,
              help: chord.fromKeymap
                  ? '${chord.command} · keymap.json'
                  : chord.command,
              controlMaxWidth: 200,
              control: SettingsValue(label: chord.label, mono: true),
            ),
        ],
      ),
    );
  }
}
