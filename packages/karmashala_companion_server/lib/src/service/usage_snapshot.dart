import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_remote/remote.dart';

/// Points of history per window on the wire: a day, thinned.
const int kRemoteUsageSamples = 48;

/// Every agent account's usage, for `usage.get` — the one answer whoever
/// serves the phone, the desktop app or the session host.
///
/// One entry per account whose agent's adapter declares a usage capability
/// (two installs of one CLI in one place share it), read through
/// [AgentUsageService.fetch] — the throttle decides whether that costs a
/// request — with the last reading kept when a fresh one is refused.
/// [history] answers a day of an account's recorded samples; [environmentName]
/// what the machine an installation lives on is called.
Future<RemoteUsageSnapshot> companionUsageSnapshot({
  required List<AgentInstallation> installations,
  required AgentRegistry registry,
  required AgentUsageService service,
  required List<ExecutionEnvironment> environments,
  required List<UsageSample> Function(String accountKey, DateTime since)
  history,
  required String Function(String environmentId) environmentName,
  required DateTime now,
}) async {
  final seen = <String>{};
  final accounts = [
    for (final installation in installations)
      // Capabilities, not names: an agent whose adapter reads no usage is
      // not offered, whichever agent it is.
      if (registry.adapterFor(installation.agentId)?.usage != null &&
          seen.add(usageAccountKey(installation)))
        installation,
  ];

  Future<RemoteUsageAccount> account(AgentInstallation installation) async {
    final key = usageAccountKey(installation);
    AgentUsage? usage;
    String? failure;
    try {
      usage = await service.fetch(installation, environments);
    } on UsageException catch (error) {
      failure = error.message;
      usage = service.remembered(installation);
    } on Object catch (error) {
      failure = 'Could not read usage: $error';
      usage = service.remembered(installation);
    }
    final samples = history(key, now.subtract(const Duration(hours: 24)));
    return RemoteUsageAccount(
      key: key,
      agentId: installation.agentId,
      agentName: registry.displayNameFor(installation.agentId),
      environment: environmentName(installation.environmentId),
      email: usage?.email,
      readAt: usage?.fetchedAt,
      failure: failure,
      windows: [
        for (final window in usage?.windows ?? const <UsageWindow>[])
          _window(window, usage!.fetchedAt, samples),
      ],
    );
  }

  return RemoteUsageSnapshot(
    accounts: await Future.wait([for (final i in accounts) account(i)]),
    observedAt: now,
  );
}

RemoteUsageWindow _window(
  UsageWindow window,
  DateTime readAt,
  List<UsageSample> history,
) {
  final pace = usagePace(window, readAt);
  return RemoteUsageWindow(
    label: window.label,
    percent: window.percent,
    resetsAt: window.resetsAt,
    span: window.span,
    pace: switch (pace.verdict) {
      UsagePaceVerdict.unknown => RemoteUsagePace.unknown,
      UsagePaceVerdict.onPace => RemoteUsagePace.onPace,
      UsagePaceVerdict.aheadOfPace => RemoteUsagePace.aheadOfPace,
      UsagePaceVerdict.overPace => RemoteUsagePace.overPace,
      UsagePaceVerdict.spent => RemoteUsagePace.spent,
    },
    limitAt: pace.limitAt,
    samples: thinUsageSamples([
      for (final sample in history)
        if (sample.windowLabel == window.label)
          RemoteUsageSample(at: sample.recordedAt, percent: sample.percent),
    ]),
  );
}

/// At most [kRemoteUsageSamples] of [samples], evenly spread, first and last
/// kept — a sparkline needs the shape, not every heartbeat.
List<RemoteUsageSample> thinUsageSamples(List<RemoteUsageSample> samples) {
  if (samples.length <= kRemoteUsageSamples) return samples;
  final step = (samples.length - 1) / (kRemoteUsageSamples - 1);
  return [
    for (var i = 0; i < kRemoteUsageSamples; i++) samples[(i * step).round()],
  ];
}
