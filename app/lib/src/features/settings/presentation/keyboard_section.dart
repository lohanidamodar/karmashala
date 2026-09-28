import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/keymap_controller.dart';
import '../../../app/shell/shell_shortcuts.dart';
import '../../editor/application/editor_tab_actions.dart';
import 'settings_catalog.dart';
import 'settings_layout.dart';
import 'settings_notice.dart';
import 'settings_section.dart';

/// Settings → Keyboard: every binding in force, read from the table
/// the keys themselves run on, so this list cannot drift from what they do.
class KeyboardSection extends ConsumerWidget {
  const KeyboardSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = ref.watch(keymapProvider);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      letterSpacing: 0,
      fontWeight: FontWeight.w400,
    );
    final chords = [...shellChords]
      ..sort((a, b) => a.command.compareTo(b.command));
    final path = status.path;
    // A narrow page stacks each chord over what it does: a fixed 132 px
    // column beside it would leave the description a sliver.
    final narrow = SettingsNarrowScope.of(context);

    return SettingsSection(
      title: SettingsAnchor.keyboard.heading,
      trailing: path == null
          ? null
          : TextButton(
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            path == null ? 'The app’s own keys.' : 'Rebind keys in $path.',
            style: theme.textTheme.bodySmall,
          ),
          if (status.problems.isNotEmpty) ...[
            const SizedBox(height: Insets.sm),
            SettingsNotice(
              tone: SettingsNoticeTone.attention,
              message: 'keymap.json is not in use; the last good one is.',
              detail: status.problems.join('\n'),
            ),
          ],
          const SizedBox(height: Insets.sm),
          for (final chord in chords)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.xs),
              child: _ChordRow(
                narrow: narrow,
                keys: Text(chord.label, style: MonoStyles.body),
                what: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(chord.does, style: theme.textTheme.bodySmall),
                    Text(
                      chord.fromKeymap
                          ? '${chord.command} · keymap.json'
                          : chord.command,
                      style: muted,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One binding: its keys beside what it does, or over it on a narrow page.
class _ChordRow extends StatelessWidget {
  const _ChordRow({
    required this.narrow,
    required this.keys,
    required this.what,
  });

  final bool narrow;
  final Widget keys;
  final Widget what;

  @override
  Widget build(BuildContext context) => narrow
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [keys, what],
        )
      : Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 132, child: keys),
            Expanded(child: what),
          ],
        );
}
