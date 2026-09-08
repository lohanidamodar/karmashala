import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../data/browser_launcher.dart';
import '../data/browser_service.dart';

/// The debugging port Karmashala attaches to (or launches a browser on).
///
/// Chrome's own default, so a browser the user started with
/// `--remote-debugging-port=9222` — and, since Chrome 136, its own
/// `--user-data-dir` — is found without configuring anything.
final browserDebugPortProvider = Provider<int>(
  (ref) => BrowserLauncher.defaultPort,
);

/// The browser driver.
///
/// Kept as a single long-lived service because a session owns a WebSocket and
/// possibly a spawned process; disposing the provider tears both down.
final browserServiceProvider = Provider<BrowserService>((ref) {
  final service = BrowserService(runner: ref.watch(hostCommandRunnerProvider));
  ref.onDispose(() => service.disconnect());
  return service;
});
