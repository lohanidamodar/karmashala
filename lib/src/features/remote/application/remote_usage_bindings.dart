import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_usage_providers.dart';
import '../../agents/application/usage_history.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environments_controller.dart';

/// Points of history per window on the wire: a day, thinned.
const int kRemoteUsageSamples = 48;

/// The agents whose usage the desktop can read at all.
const Set<String> kUsageAgents = {
  AgentIds.claudeCode,
  AgentIds.codex,
  AgentIds.antigravity,
};

/// Every agent account's usage, for `usage.get`: one entry per account (two
/// installs of one CLI in one place share it), read through
/// [AgentUsageService.fetch] — the throttle decides whether that costs a
/// request — with the last reading kept when a fresh one is refused.
Future<RemoteUsageSnapshot> remoteUsageSnapshot(Ref ref) async {
  final service = ref.read(agentUsageServiceProvider);
  final environments = ref.read(executionEnvironmentDaoProvider).getAll();
  final registry = ref.read(agentRegistryProvider);
  final now = ref.read(clockProvider).nowUtc();
  final seen = <String>{};
  final installations = [
    for (final installation in ref.read(agentInstallationsControllerProvider))
      if (kUsageAgents.contains(installation.agentId) &&
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
    final history = ref
        .read(usageSampleDaoProvider)
        .since(key, now.subtract(const Duration(hours: 24)));
    return RemoteUsageAccount(
      key: key,
      agentId: installation.agentId,
      agentName: registry.displayNameFor(installation.agentId),
      environment: ref.read(
        environmentLabelForIdProvider(installation.environmentId),
      ),
      email: usage?.email,
      readAt: usage?.fetchedAt,
      failure: failure,
      windows: [
        for (final window in usage?.windows ?? const <UsageWindow>[])
          _window(window, usage!.fetchedAt, history),
      ],
    );
  }

  return RemoteUsageSnapshot(
    accounts: await Future.wait([for (final i in installations) account(i)]),
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
