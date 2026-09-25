import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_hook_sweep.dart';
import 'local_host_providers.dart';

/// **This machine's session host, started or adopted as the app starts** — and
/// then local agents' hooks pointed at the endpoint it writes — while local
/// panes are host-backed. Null when there is nothing to start: host-backed
/// panes are off, or no host may be reached here (a test, a companion build, a
/// probe with no data folder).
///
/// The host owns the agent hook endpoint and the lifecycle feed, so the first
/// session's first turn is heard only if the host is up before that turn runs.
/// Left to the first host-backed pane, it was not: the turn's hooks went
/// nowhere. So the order is host, hooks, feed: the lifecycle subscriber dials
/// once this resolves, and the launch's own hook sweep waits for it too.
///
/// The start is the pane's own [LocalHostSessionAccess.deployment], memoised on
/// the access, so a pane opening meanwhile shares it rather than starting a
/// second host — and an older host holding running sessions is left running,
/// exactly as a pane leaves it. **Never fails**: a host that cannot be started
/// is logged, and panes keep their fallback.
final localHostStartupProvider = Provider<Future<HostDeployment?>?>((ref) {
  final access = ref.watch(localHostSessionAccessProvider);
  // Asked second, so that with no host possible the settings are never read.
  if (access == null || !ref.watch(hostBackedLocalPanesProvider)) return null;
  return _startLocalHost(ref.container, access);
});

Future<HostDeployment?> _startLocalHost(
  ProviderContainer container,
  LocalHostSessionAccess access,
) async {
  final log = AppLogger.named('host.local');
  HostDeployment? reading;
  try {
    reading = await access.deployment();
    if (reading.status == HostDeploymentStatus.ready) {
      log.info('Session host at launch: ${reading.reason}');
    } else {
      log.warning(
        'The session host is not up at launch (${reading.status.name}): '
        '${reading.reason}',
      );
    }
  } on Object catch (error, stack) {
    log.warning('Starting the session host at launch failed.', error, stack);
  }
  // Only once the start has settled, so the endpoint read is the live host's.
  // Nothing when hooks are the app's, in a probe, or with no endpoint written.
  await sweepHostHooks(container, logger: AppLogger.named('agent-hooks'));
  return reading;
}
