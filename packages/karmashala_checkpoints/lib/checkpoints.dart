/// A checkpoint: one snapshot of a working tree, as git holds it — the value,
/// its wire shape, the rules a copy answers with (turn edges, titles, fork and
/// restore words, the settings), and the service that captures and restores
/// one over a [CheckpointRecords] port.
library;

export 'src/domain/checkpoint.dart';
export 'src/domain/checkpoint_json.dart';
export 'src/domain/checkpoint_fork.dart';
export 'src/domain/checkpoint_rules.dart';
export 'src/domain/checkpoint_screenshot.dart';
export 'src/domain/checkpoint_settings.dart';
export 'src/domain/checkpoint_title.dart';
export 'src/domain/screenshot_diff.dart';
export 'src/domain/turn_boundary.dart';
export 'src/service/checkpoint_records.dart';
export 'src/service/checkpoint_service.dart';
export 'src/service/restore_answer.dart';
