import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/agent_usage_providers.dart';
import '../../agents/data/agents_data.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environments_controller.dart';

/// Every agent account's usage, for `usage.get`: the one snapshot the session
/// host builds too ([companionUsageSnapshot]), from this app's service — whose
/// throttle and history the Settings panel and the chip share.
Future<RemoteUsageSnapshot> remoteUsageSnapshot(Ref ref) =>
    companionUsageSnapshot(
      installations: ref.read(agentInstallationsControllerProvider),
      registry: ref.read(agentRegistryProvider),
      service: ref.read(agentUsageServiceProvider),
      environments: ref.read(environmentsDataProvider).getAll(),
      history: ref.read(usageHistoryDataProvider).since,
      environmentName: (id) => ref.read(environmentLabelForIdProvider(id)),
      now: ref.read(clockProvider).nowUtc(),
    );
