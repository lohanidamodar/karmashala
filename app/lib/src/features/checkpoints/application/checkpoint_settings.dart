import 'dart:convert';

import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';

export 'package:karmashala_checkpoints/checkpoints.dart'
    show
        CheckpointSettings,
        kCheckpointRetentionChoices,
        kCheckpointSettingsKey,
        kDefaultCheckpointRetention;

/// Settings › Agents › Checkpoints, as a preference the server's recorder
/// reads before each turn: writing it is all a change takes.
class CheckpointSettingsController extends Notifier<CheckpointSettings> {
  @override
  CheckpointSettings build() {
    final raw = ref.read(appPreferencesProvider).read(kCheckpointSettingsKey);
    if (raw == null) return const CheckpointSettings();
    try {
      return CheckpointSettings.fromJson(jsonDecode(raw));
    } on FormatException {
      return const CheckpointSettings();
    }
  }

  void setAutomatic(bool value) => _save(state.copyWith(automatic: value));

  void setKeepPerRepository(int? value) =>
      _save(state.copyWith(keep: () => value));

  void _save(CheckpointSettings next) {
    state = next;
    ref
        .read(appPreferencesProvider)
        .write(kCheckpointSettingsKey, jsonEncode(next.toJson()));
  }
}

final checkpointSettingsProvider =
    NotifierProvider<CheckpointSettingsController, CheckpointSettings>(
      CheckpointSettingsController.new,
    );
