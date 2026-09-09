import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../data/terminal_preset_dao.dart';
import '../domain/terminal_preset.dart';
import 'terminal_sessions_controller.dart';

final terminalPresetDaoProvider = Provider<TerminalPresetDao>(
  (ref) => TerminalPresetDao(ref.watch(databaseProvider)),
);

/// Saving and opening a named workbench shape.
///
/// Thin on purpose: the shape is captured and rebuilt by
/// [TerminalSessionsController], which is the only thing that knows what a tab
/// is; this is where the store and the clock meet it.
class TerminalPresets {
  const TerminalPresets(this._ref);

  final Ref _ref;

  TerminalPresetDao get _dao => _ref.read(terminalPresetDaoProvider);

  List<TerminalPreset> all() => _dao.getAll();

  /// Saves the workbench as it stands under [name].
  ///
  /// A name already in use is **replaced rather than duplicated**: saving twice
  /// under one name is somebody correcting a preset, not asking for two. The id
  /// is kept across the replacement because anything referring to the preset
  /// holds that, not the name. Returns null when there is nothing to capture —
  /// a workbench of empty regions declares nothing.
  TerminalPreset? save(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final existing = _dao.getAll().where((p) => p.name == trimmed).firstOrNull;
    final preset = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .capturePreset(
          id: existing?.id ?? _ref.read(idGeneratorProvider).newId(),
          name: trimmed,
        );
    if (preset.tabs.isEmpty) return null;
    _dao.save(preset, _ref.read(clockProvider).nowUtc());
    return preset;
  }

  TerminalPresetOpening open(TerminalPreset preset) => _ref
      .read(terminalSessionsControllerProvider.notifier)
      .openPreset(preset);

  void delete(String id) => _dao.delete(id);
}

final terminalPresetsProvider = Provider<TerminalPresets>(
  TerminalPresets.new,
);

/// What to tell the user after opening [preset] gave [opening].
///
/// Named profiles rather than a count, because the count says nothing anybody
/// can act on. Null when nothing was skipped: a preset that opened whole does
/// not need announcing.
String? presetOpenedMessage(
  TerminalPreset preset,
  TerminalPresetOpening opening,
) {
  if (!opening.skippedAnything) return null;
  final skipped = opening.skippedProfileIds.join(', ');
  if (opening.openedPanes == 0) {
    return 'Nothing in "${preset.name}" could be opened — '
        'this machine has no $skipped.';
  }
  return 'Opened "${preset.name}" without $skipped — '
      'this machine no longer has that profile.';
}
