import 'dart:typed_data';

import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:riverpod/riverpod.dart';

import '../data/visuals_data.dart';

/// Moves whenever any visual is drawn or updated, here or on another client.
class VisualsRevisionController extends Notifier<int> {
  @override
  int build() {
    final listening = ref
        .watch(visualsDataProvider)
        .changes
        .listen((_) => state = state + 1);
    ref.onDispose(listening.cancel);
    return 0;
  }
}

final visualsRevisionProvider =
    NotifierProvider<VisualsRevisionController, int>(
      VisualsRevisionController.new,
    );

/// [sessionId]'s visuals, first drawn first.
final sessionVisualsProvider = FutureProvider.autoDispose
    .family<List<SessionVisual>, String>((ref, sessionId) async {
      ref.watch(visualsRevisionProvider);
      return ref.watch(visualsDataProvider).forSession(sessionId);
    }, retry: (_, _) => null);

/// One visual as it now stands, or null while unknown.
final sessionVisualProvider = Provider.autoDispose
    .family<SessionVisual?, ({String sessionId, String id})>((ref, key) {
      final list = ref.watch(sessionVisualsProvider(key.sessionId)).value;
      return list?.where((v) => v.id == key.id).firstOrNull;
    });

/// An image visual's bytes at one revision.
final visualImageProvider = FutureProvider.autoDispose
    .family<Uint8List, ({String sessionId, String id, int revision})>(
      (ref, key) => ref
          .watch(visualsDataProvider)
          .image(key.sessionId, key.id, key.revision),
      retry: (_, _) => null,
    );
