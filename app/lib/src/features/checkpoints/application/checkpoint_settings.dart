import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';

/// The choices offered for how many checkpoints a session keeps per repository.
/// `null` keeps every one.
const List<int?> kCheckpointRetentionChoices = [50, 100, 200, 500, null];

const int kDefaultCheckpointRetention = 200;

/// Whether turns are checkpointed, and how many a session keeps per
/// repository. In its own metadata key so the settings document stays as it is.
class CheckpointSettings {
  const CheckpointSettings({
    this.automatic = true,
    this.keepPerRepository = kDefaultCheckpointRetention,
  });

  final bool automatic;

  /// The newest checkpoints kept of each repository a session checkpoints, or
  /// `null` to keep them all.
  final int? keepPerRepository;

  CheckpointSettings copyWith({bool? automatic, int? Function()? keep}) =>
      CheckpointSettings(
        automatic: automatic ?? this.automatic,
        keepPerRepository: keep == null ? keepPerRepository : keep(),
      );

  Map<String, Object?> toJson() => {
    'automatic': automatic,
    'keepPerRepository': keepPerRepository,
  };

  static CheckpointSettings fromJson(Object? json) {
    if (json is! Map) return const CheckpointSettings();
    final keep = json['keepPerRepository'];
    return CheckpointSettings(
      automatic: json['automatic'] is bool ? json['automatic'] as bool : true,
      keepPerRepository: json.containsKey('keepPerRepository')
          ? (keep is int && keep > 0 ? keep : null)
          : kDefaultCheckpointRetention,
    );
  }
}

const String kCheckpointSettingsKey = 'checkpoints.settings.v1';

class CheckpointSettingsController extends Notifier<CheckpointSettings> {
  @override
  CheckpointSettings build() {
    final raw = ref.read(databaseProvider).readMetadata(kCheckpointSettingsKey);
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
        .read(databaseProvider)
        .writeMetadata(kCheckpointSettingsKey, jsonEncode(next.toJson()));
  }
}

final checkpointSettingsProvider =
    NotifierProvider<CheckpointSettingsController, CheckpointSettings>(
      CheckpointSettingsController.new,
    );
