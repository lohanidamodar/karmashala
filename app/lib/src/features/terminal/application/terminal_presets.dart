import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_snippets/karmashala_snippets.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'terminal_sessions_controller.dart';

/// Saving and opening a named workbench shape, kept at the server. The shape
/// is captured and rebuilt by [TerminalSessionsController].
class TerminalPresets {
  const TerminalPresets(this._ref);

  static final _log = AppLogger.named('terminal.presets');

  final Ref _ref;

  DataClient get _client => _ref.read(dataClientProvider);

  /// Every preset this build can open, the one touched last first.
  List<TerminalPreset> all() => [
    for (final stored in [..._client.presets.values]..sort(comparePresets))
      ?TerminalPreset.fromJson(
        id: stored.id,
        name: stored.name,
        shape: stored.shape,
      ),
  ];

  /// Saves the workbench as it stands under [name]. A name already in use is
  /// replaced, keeping its id. Null when there is nothing to capture.
  TerminalPreset? save(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final preset = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .capturePreset(
          id: presetIdFor(
            trimmed,
            _ref.read(idGeneratorProvider).newId(),
            _client.presets.values,
          ),
          name: trimmed,
        );
    if (preset.tabs.isEmpty) return null;
    final shape = preset.toJson();
    _client.presets.setLocal(
      preset.id,
      StoredPreset(
        id: preset.id,
        name: trimmed,
        shape: shape,
        updatedAt: _ref.read(clockProvider).nowUtc(),
      ),
    );
    _send(PresetSave(id: preset.id, presetName: trimmed, shape: shape));
    return preset;
  }

  TerminalPresetOpening open(TerminalPreset preset) =>
      _ref.read(terminalSessionsControllerProvider.notifier).openPreset(preset);

  void delete(String id) {
    _client.presets.setLocal(id, null);
    _send(PresetDelete(id));
  }

  void _send<R>(DataRequest<R> request) => unawaited(
    _client
        .write(request, domain: DataDomain.snippets)
        .then<void>(
          (_) {},
          onError: (Object error) =>
              _log.warning('${request.kind} was refused: $error'),
        ),
  );
}

final terminalPresetsProvider = Provider<TerminalPresets>(TerminalPresets.new);

/// What to tell the user after opening [preset] gave [opening]. Named profiles
/// rather than a count; null when nothing was skipped.
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
