import 'package:agent_cli/discovery.dart' as agent_cli;
import 'package:karmashala_core/paths.dart';
import 'package:karmashala_core/util.dart';
import 'package:riverpod/riverpod.dart';

import '../paths/path_probe_provider.dart';
import 'clock_provider.dart';

/// The app's `Clock` and `PathProbe`, spelled the way
/// `package:agent_cli` spells them — it carries its own copies.
class _BridgedClock implements agent_cli.Clock {
  const _BridgedClock(this._clock);

  final Clock _clock;

  @override
  DateTime nowUtc() => _clock.nowUtc();
}

class _BridgedPathProbe implements agent_cli.PathProbe {
  const _BridgedPathProbe(this._probe);

  final PathProbe _probe;

  @override
  bool? fileExists(String path) => _probe.fileExists(path);

  @override
  bool isLink(String path) => _probe.isLink(path);

  @override
  String? linkTarget(String path) => _probe.linkTarget(path);
}

/// [clock] as the package sees it.
agent_cli.Clock agentCliClock(Clock clock) => _BridgedClock(clock);

/// [probe] as the package sees it.
agent_cli.PathProbe agentCliPathProbe(PathProbe probe) =>
    _BridgedPathProbe(probe);

/// The workspace's one clock, for the package's services. A provider of its
/// own, so a test overriding [clockProvider] also pins the package's time.
final agentCliClockProvider = Provider<agent_cli.Clock>(
  (ref) => agentCliClock(ref.watch(clockProvider)),
);

/// The workspace's one path probe, for the package's discovery and repair.
final agentCliPathProbeProvider = Provider<agent_cli.PathProbe>(
  (ref) => agentCliPathProbe(ref.watch(pathProbeProvider)),
);
