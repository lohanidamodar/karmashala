import 'dart:async';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/process/command_runner_providers.dart';
import 'local_relay_service.dart';

/// The one embedded relay. Constructing it starts nothing — only
/// `ensureRunning` binds — and `AppLifecycle` owns the budgeted stop.
final localRelayServiceProvider = Provider<LocalRelayService>((ref) {
  final logger = AppLogger.named('remote');
  final service = LocalRelayService(
    // netsh exists only on Windows; elsewhere the OS prompt is the story.
    firewall: Platform.isWindows ? ref.watch(hostCommandRunnerProvider) : null,
    onLog: logger.info,
  );
  // A backstop — the lifecycle's 'local relay' step is the real teardown.
  ref.onDispose(() => unawaited(service.stop()));
  return service;
});

/// The relay's live status, re-read whenever the service reports a change.
final localRelayStatusProvider = Provider<LocalRelayStatus>((ref) {
  final service = ref.watch(localRelayServiceProvider);
  final subscription = service.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(subscription.cancel);
  return service.status;
});
