import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostics.dart';
import 'diagnostics_bootstrap.dart';

/// The app's log sinks. A provider over the process-wide instance so a test can
/// hand the UI its own without touching a global.
final diagnosticsProvider = Provider<Diagnostics>(
  (ref) => Diagnostics.instance,
);

/// Where the log files live, for the reveal button and the folder line.
final logDirectoryProvider = FutureProvider<Directory>(
  (ref) => defaultLogDirectory(),
);
