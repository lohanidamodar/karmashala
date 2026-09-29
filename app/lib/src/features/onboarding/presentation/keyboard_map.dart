import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/keymap_controller.dart';
import '../../../app/shell/shell_shortcuts.dart';

/// The keys an empty workspace and the quick start offer, by command: the few
/// a newcomer needs to find everything else.
const kWorkspaceKeyCommands = [
  'quickOpen.show',
  'quickOpen.commands',
  'session.new',
  'project.new',
  'attention.nextWaiting',
  'settings.open',
];

/// The chord [command] is on now, preferring the one a focused pane lets
/// through; null when the keymap left it without keys.
ShellChord? boundShellChord(String command) {
  ShellChord? best;
  for (final chord in shellChords) {
    if (chord.command != command) continue;
    if (best == null || (!best.skipsShell && chord.skipsShell)) best = chord;
  }
  return best;
}

/// **A live keyboard map** for a narrow column: what each of [commands] does
/// and the keys it is on, read from the resolved keymap, so an edit to the
/// keymap file shows at once. A command the keymap unbound is left out rather
/// than shown keyless. The empty workspace draws the same list centred.
class KeyboardMap extends ConsumerWidget {
  const KeyboardMap({this.commands = kWorkspaceKeyCommands, super.key});

  final List<String> commands;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(keymapProvider.select((k) => k.revision));
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final rows = [for (final command in commands) ?boundShellChord(command)];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final chord in rows)
          Semantics(
            label: '${chord.does}: ${chord.label}',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: Insets.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      chord.does,
                      style: muted,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  Text(chord.label, style: MonoStyles.small),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
