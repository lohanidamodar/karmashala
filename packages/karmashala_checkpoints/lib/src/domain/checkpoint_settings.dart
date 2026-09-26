/// The choices offered for how many checkpoints a session keeps per repository.
/// `null` keeps every one.
const List<int?> kCheckpointRetentionChoices = [50, 100, 200, 500, null];

const int kDefaultCheckpointRetention = 200;

/// The preference the settings are kept under: a client writes it, the
/// server's recorder reads it before each turn.
const String kCheckpointSettingsKey = 'checkpoints.settings.v1';

/// Whether turns are checkpointed, and how many a session keeps per
/// repository. In its own preference so the settings document stays as it is.
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

/// How far past its limit a repository's chain may grow before it is pruned,
/// so a session at its limit does not re-commit the whole chain every turn.
int checkpointPruneSlack(int keep) => keep ~/ 10 < 10 ? 10 : keep ~/ 10;
