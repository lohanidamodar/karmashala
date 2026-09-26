/// A checkpoint: one snapshot of a working tree, as git holds it — the value,
/// its wire shape, the rules a copy answers with, and the service that
/// captures and restores one over a [CheckpointRecords] port.
library;

export 'src/domain/checkpoint.dart';
export 'src/domain/checkpoint_json.dart';
export 'src/domain/checkpoint_rules.dart';
export 'src/service/checkpoint_records.dart';
export 'src/service/checkpoint_service.dart';
