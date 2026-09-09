import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../data/environment_discovery_service.dart';

/// Provides the environment discovery service, wired to the host command runner.
final environmentDiscoveryServiceProvider =
    Provider<EnvironmentDiscoveryService>(
      (ref) => EnvironmentDiscoveryService(
        host: ref.watch(hostCommandRunnerProvider),
        clock: ref.watch(clockProvider),
      ),
    );
