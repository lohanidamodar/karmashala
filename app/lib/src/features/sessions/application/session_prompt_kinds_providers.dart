import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';

/// Whether [sessionId]'s agent takes an attached image as an image rather
/// than as its path, as the server last told (`SessionPromptKindsChanged`);
/// false until it has said.
final sessionTakesImagesProvider = Provider.autoDispose.family<bool, String>((
  ref,
  sessionId,
) {
  final client = ref.watch(dataClientProvider);
  final told = client.sessionPromptKindChanges.listen((change) {
    if (change.sessionId == sessionId) ref.invalidateSelf();
  });
  ref.onDispose(told.cancel);
  return client.sessionPromptKinds[sessionId]?.images ?? false;
});
