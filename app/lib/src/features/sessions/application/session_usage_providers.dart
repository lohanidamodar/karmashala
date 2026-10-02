import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';

/// What [sessionId]'s agent last reported of its own context and cost over
/// its protocol (`SessionUsageChanged`); null until it has said. In memory
/// only, like the agent's modes: `sessions.stats` holds the kept copy.
final sessionUsageProvider = Provider.autoDispose
    .family<SessionUsageChanged?, String>((ref, sessionId) {
      final client = ref.watch(dataClientProvider);
      final told = client.sessionUsageChanges.listen((change) {
        if (change.sessionId == sessionId) ref.invalidateSelf();
      });
      ref.onDispose(told.cancel);
      return client.sessionUsage[sessionId];
    });
