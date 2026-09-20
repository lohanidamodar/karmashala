/// Structured logging and the in-app diagnostics buffer.
///
/// `AppLogger` wraps `package:logging`; `Diagnostics` fans a record out to the
/// ring buffer the Logs panel reads and to a redacted file sink.
library;

export 'src/logging/app_logger.dart';
export 'src/logging/build_identity.dart';
export 'src/logging/diagnostics.dart';
export 'src/logging/log_buffer.dart';
export 'src/logging/log_entry.dart';
export 'src/logging/log_file_sink.dart';
export 'src/logging/log_redactor.dart';
export 'src/logging/memory_census.dart';
