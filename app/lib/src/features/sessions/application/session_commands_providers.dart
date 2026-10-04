import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';

/// The slash commands [sessionId]'s agent accepts, as the server last told
/// them (`SessionCommandsChanged`); empty until it has said. In memory only —
/// the agent announces them again when the session resumes.
final sessionCommandsProvider = Provider.autoDispose
    .family<List<SessionCommand>, String>((ref, sessionId) {
      final client = ref.watch(dataClientProvider);
      final told = client.sessionCommandChanges.listen((change) {
        if (change.sessionId == sessionId) ref.invalidateSelf();
      });
      ref.onDispose(told.cancel);
      return client.sessionCommands[sessionId]?.commands ?? const [];
    });
