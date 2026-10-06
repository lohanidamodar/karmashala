import 'dart:typed_data';

import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:riverpod/riverpod.dart';

import '../data/artifacts_data.dart';

/// Moves whenever any artifact is shown, revised or found missing — here or
/// on another client — so lists refresh without polling.
class ArtifactsRevisionController extends Notifier<int> {
  @override
  int build() {
    final listening = ref
        .watch(artifactsDataProvider)
        .changes
        .listen((_) => state = state + 1);
    ref.onDispose(listening.cancel);
    return 0;
  }
}

final artifactsRevisionProvider =
    NotifierProvider<ArtifactsRevisionController, int>(
      ArtifactsRevisionController.new,
    );

/// [sessionId]'s artifacts, oldest first. None of these retries on its own:
/// a view says why a read failed, and the next change asks again.
final sessionArtifactsProvider = FutureProvider.autoDispose
    .family<List<Artifact>, String>((ref, sessionId) async {
      ref.watch(artifactsRevisionProvider);
      return ref.watch(artifactsDataProvider).forSession(sessionId);
    }, retry: (_, _) => null);

/// [sessionId]'s artifact [id] as it now stands, or null while unknown.
final sessionArtifactProvider = Provider.autoDispose
    .family<Artifact?, ({String sessionId, String id})>((ref, key) {
      final list = ref.watch(sessionArtifactsProvider(key.sessionId)).value;
      return list?.where((a) => a.id == key.id).firstOrNull;
    });

/// The bytes of one revision. Keyed by revision, so a new revision is a new
/// read and an old one stays put while it is looked at.
final artifactContentProvider = FutureProvider.autoDispose
    .family<Uint8List, ({String id, int revision})>(
      (ref, key) => ref.watch(artifactsDataProvider).content(key.id, key.revision),
      retry: (_, _) => null,
    );

/// The revisions of [id] the server still keeps, oldest first.
final artifactRevisionsProvider = FutureProvider.autoDispose
    .family<List<ArtifactRevisionSummary>, String>((ref, id) {
      ref.watch(artifactsRevisionProvider);
      return ref.watch(artifactsDataProvider).revisions(id);
    }, retry: (_, _) => null);

/// Lets an artifact reach the network, or takes it back — the server's one
/// setting, so every client follows it.
final setArtifactNetworkProvider =
    Provider<Future<Artifact> Function(String id, {required bool allowed})>(
      (ref) => ref.watch(artifactsDataProvider).setNetwork,
    );
