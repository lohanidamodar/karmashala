import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/tokens.dart';

import 'package:karmashala_core/apps.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../application/settings_controller.dart';
import '../domain/settings.dart';
import 'choose_application_dialog.dart';
import 'path_field_row.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Which external program an [ExternalAppSection] picks, and everything that
/// differs between the two: the words, and which settings it reads and writes.
enum ExternalAppKind {
  /// The terminal a session resumes in.
  terminal(
    anchor: SettingsAnchor.externalTerminal,
    rowLabel: 'Open sessions in',
    pathLabel: 'Terminal executable path',
    program: 'terminal',
    aProgram: 'a terminal',
    note: 'Best effort: flags vary by terminal.',
  ),

  /// The editor "open in editor" hands a folder to.
  editor(
    anchor: SettingsAnchor.externalEditor,
    rowLabel: 'Open folders in',
    pathLabel: 'Editor executable path',
    program: 'editor',
    aProgram: 'an editor',
    note: 'Opens with the folder path as its argument.',
  );

  const ExternalAppKind({
    required this.anchor,
    required this.rowLabel,
    required this.pathLabel,
    required this.program,
    required this.aProgram,
    required this.note,
  });

  final SettingsAnchor anchor;
  final String rowLabel;
  final String pathLabel;

  /// The program's plain name, as in "terminal.exe".
  final String program;

  /// The same with its article, as in "a terminal program".
  final String aProgram;

  /// What happens with the chosen program, under its path field.
  final String note;

  /// The detected programs, as `(id, label)`; empty while the probe runs.
  List<({String id, String label})> detected(WidgetRef ref) => switch (this) {
    terminal => [
      for (final t
          in ref.watch(availableSystemTerminalsProvider).asData?.value ??
              const [])
        (id: t.id, label: t.label),
    ],
    editor => [
      for (final e
          in ref.watch(availableCodeEditorsProvider).asData?.value ?? const [])
        (id: e.id, label: e.label),
    ],
  };

  String? savedId(Settings settings) => switch (this) {
    terminal => settings.defaultSystemTerminalId,
    editor => settings.defaultCodeEditorId,
  };

  String? customPath(Settings settings) => switch (this) {
    terminal => settings.customTerminalPath,
    editor => settings.customEditorPath,
  };

  void setDefault(SettingsController controller, String id) => switch (this) {
    terminal => controller.setDefaultSystemTerminal(id),
    editor => controller.setDefaultCodeEditor(id),
  };

  void setCustomPath(SettingsController controller, String path) =>
      switch (this) {
        terminal => controller.setCustomTerminalPath(path),
        editor => controller.setCustomEditorPath(path),
      };
}

/// The id the dropdown holds for "a path of your own".
const _custom = 'custom';

/// An external program Karmashala hands work to: a detected one, or a custom
/// path chosen from the installed applications or browsed to.
class ExternalAppSection extends ConsumerStatefulWidget {
  const ExternalAppSection({required this.kind, super.key});

  final ExternalAppKind kind;

  @override
  ConsumerState<ExternalAppSection> createState() => _ExternalAppSectionState();
}

class _ExternalAppSectionState extends ConsumerState<ExternalAppSection> {
  final _path = TextEditingController();

  ExternalAppKind get _kind => widget.kind;

  @override
  void initState() {
    super.initState();
    _path.text = _kind.customPath(ref.read(settingsControllerProvider)) ?? '';
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    // The program runs on this device, so it is picked from this device.
    final file = await pickDeviceFile(
      context: context,
      what: '${_kind.aProgram} program',
      startNear: _path.text,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Executables', extensions: ['exe']),
      ],
    );
    if (file == null) return;
    _use(file.path);
  }

  Future<void> _choose() async {
    final app = await chooseInstalledApplication(
      context,
      what: '${_kind.aProgram} application',
    );
    if (app == null) return;
    _use(app.launchPath);
  }

  void _use(String path) {
    _path.text = path;
    _kind.setCustomPath(ref.read(settingsControllerProvider.notifier), path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final detected = _kind.detected(ref);
    // Clamp to a valid option: the saved program can be absent from
    // `detected` while the probe loads, and DropdownButtonFormField throws.
    final validIds = <String>{for (final d in detected) d.id, _custom};
    final saved = _kind.savedId(settings);
    final current = (saved != null && validIds.contains(saved))
        ? saved
        : (detected.isNotEmpty ? detected.first.id : _custom);

    return SettingsSection(
      title: _kind.anchor.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsRow(
            label: _kind.rowLabel,
            control: DropdownButtonFormField<String>(
              initialValue: current,
              isExpanded: true,
              items: [
                for (final d in detected)
                  DropdownMenuItem(
                    value: d.id,
                    child: Text(
                      d.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                DropdownMenuItem(
                  value: _custom,
                  child: Text(
                    _customLabel(_kind.customPath(settings)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (v) {
                if (v == null) return;
                if (v == _custom) {
                  _kind.setCustomPath(controller, _path.text.trim());
                } else {
                  _kind.setDefault(controller, v);
                }
              },
            ),
          ),
          if (current == _custom) ...[
            const SizedBox(height: Insets.sm),
            PathFieldRow(
              controller: _path,
              label: _kind.pathLabel,
              hint: _hostPathHint(_kind.program),
              onChanged: (v) => _kind.setCustomPath(controller, v.trim()),
              actions: [
                OutlinedButton.icon(
                  onPressed: _choose,
                  icon: const Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
                  label: const Text('Choose app'),
                ),
                OutlinedButton.icon(
                  onPressed: _browse,
                  icon: const Icon(AppIcons.folderOpen, size: Chrome.icon),
                  label: const Text('Browse'),
                ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            Text(_kind.note, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// What the dropdown's last entry says: the application already chosen, by
/// name, or the invitation to choose one. "Custom executable…" read as the
/// only way in even once something was set.
String _customLabel(String? path) {
  final chosen = (path ?? '').trim();
  return chosen.isEmpty
      ? 'Another application…'
      : '${applicationNameFor(chosen)} (chosen)';
}

String _hostPathHint(String what) {
  if (Platform.isWindows) return 'C:\\path\\to\\$what.exe';
  if (Platform.isMacOS) return '/Applications/My$what.app/Contents/MacOS/$what';
  return '/usr/local/bin/$what';
}
