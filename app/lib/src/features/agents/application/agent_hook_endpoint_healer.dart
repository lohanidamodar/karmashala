import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';

import 'agent_hook_sweep.dart';

/// Checks the local agents' hook endpoint files every [interval] and rewrites
/// any that went missing, so a deleted one does not stay silent until relaunch.
class AgentHookEndpointHealer {
  AgentHookEndpointHealer(
    this._container, {
    this.interval = defaultInterval,
    this.logger,
  });

  /// A few small file reads per tick.
  static const Duration defaultInterval = Duration(minutes: 1);

  final ProviderContainer _container;
  final Duration interval;
  final AppLogger? logger;
  Timer? _timer;
  Future<bool>? _checking;

  bool get isRunning => _timer != null;

  void start() => _timer ??= Timer.periodic(interval, (_) => unawaited(check()));

  /// One check now; a tick that lands while one runs joins it.
  Future<bool> check() => _checking ??= healAgentHookEndpoints(
    _container,
    logger: logger,
  ).whenComplete(() => _checking = null);

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
