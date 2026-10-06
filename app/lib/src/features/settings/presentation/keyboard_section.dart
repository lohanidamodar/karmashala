import 'dart:async';

import 'package:flutter/material.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/code.dart' show CodeEditorKeys;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/keymap.dart';
import '../../../app/shell/keymap_controller.dart';
import '../../../app/shell/shell_area.dart' show shellCommandShownWith;
import '../../../core/capabilities/capabilities.dart';
import '../../editor/application/editor_tab_actions.dart';
import '../application/settings_controller.dart';
import 'copyable_name.dart';
import 'settings_catalog.dart';
import 'settings_notice.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Keyboard: the shortcut browser. Every binding in force, read
/// from the resolved tables the keys themselves run on — the app's, a focused
/// terminal's and the code editor's — then every command left without keys,
/// so this list cannot drift from what the keys do.
class KeyboardSection extends ConsumerStatefulWidget {
  const KeyboardSection({super.key});

  @override
  ConsumerState<KeyboardSection> createState() => _KeyboardSectionState();
}

class _KeyboardSectionState extends ConsumerState<KeyboardSection> {
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    _filter.addListener(() => setState(() {}));
    CodeEditorKeys.revision.addListener(_onEditorKeys);
  }

  @override
  void dispose() {
    CodeEditorKeys.revision.removeListener(_onEditorKeys);
    _filter.dispose();
    super.dispose();
  }

  void _onEditorKeys() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(keymapProvider);
    final overrides = ref.watch(
      settingsControllerProvider.select((s) => s.terminalChordOverrides),
    );
    final path = status.path;
    final query = _filter.text.trim();
    final caps = ref.watch(capabilitiesProvider);
    final bindings = [
      for (final binding in resolvedKeymapBindings(overrides))
        if (shellCommandShownWith(binding.command, caps) &&
            matchesSearchAny(query, [
              binding.does,
              binding.command,
              binding.keys,
            ]))
          binding,
    ];
    List<KeymapBinding> where(bool Function(KeymapBinding b) test) => [
      for (final binding in bindings)
        if (test(binding)) binding,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: SettingsAnchor.keyboard.heading,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (path == null)
                const SettingsNote('The app’s own keys.')
              else
                SettingsRow(
                  label: 'Keymap',
                  help:
                      'Rebind, unbind or chain keys in $path. It is read '
                      'again when the window regains focus and when it is '
                      'saved here.',
                  controlMaxWidth: 280,
                  control: Wrap(
                    spacing: Insets.xs,
                    alignment: WrapAlignment.end,
                    children: [
                      TextButton(
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
                      TextButton(
                        key: const ValueKey('keymap-reload'),
                        onPressed: () => unawaited(
                          ref.read(keymapProvider.notifier).reload(force: true),
                        ),
                        child: const Text('Reload'),
                      ),
                    ],
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
              SettingsRuled(
                child: SearchField(
                  key: const ValueKey('keymap-filter'),
                  controller: _filter,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(
                      AppIcons.magnifyingGlass,
                      size: Chrome.icon,
                    ),
                    hintText: 'Filter by what it does, command id or keys',
                  ),
                ),
              ),
            ],
          ),
        ),
        _group('Everywhere', where((b) => b.keys != null && b.when == null)),
        _group(
          'Outside a terminal',
          where((b) => b.keys != null && b.when == KeymapWhen.notTerminalFocus),
          note:
              'A focused terminal keeps these keys for the shell. '
              'Settings › Terminal hands contested ones back.',
        ),
        _group(
          'In a terminal',
          where((b) => b.keys != null && b.when == KeymapWhen.terminalFocus),
        ),
        _group(
          'In the editor',
          where((b) => b.keys != null && b.when == KeymapWhen.editorFocus),
        ),
        _group(
          'No keys — quick open and menus',
          where((b) => b.keys == null),
          note: 'Bind any of these in keymap.json by its command id.',
        ),
      ],
    );
  }

  Widget _group(String title, List<KeymapBinding> rows, {String? note}) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return SettingsSection(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (note != null) SettingsNote(note),
          for (final binding in rows)
            SettingsRow(
              label: binding.does,
              // The id is what keymap.json binds by, so it can be copied.
              helpWidget: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: CopyableName(
                      text: binding.command,
                      tooltip: 'Copy command id',
                    ),
                  ),
                  if (binding.fromKeymap) const Text('· keymap.json'),
                ],
              ),
              controlMaxWidth: 200,
              control: SettingsValue(
                label: binding.keys ?? 'Unbound',
                mono: binding.keys != null,
              ),
            ),
        ],
      ),
    );
  }
}
