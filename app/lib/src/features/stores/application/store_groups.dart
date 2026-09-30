import 'package:store_console/store_console.dart';

/// One app on one store, with what was read about it — null until it has
/// been read.
class StoreEntry {
  const StoreEntry(this.app, this.snapshot);

  final StoreApp app;
  final StoreAppSnapshot? snapshot;

  /// The release that most wants looking at: one somebody must act on, else
  /// one on its way.
  StoreRelease? get pending {
    final pending = snapshot?.pending ?? const <StoreRelease>[];
    for (final release in pending) {
      if (release.state.needsAttention) return release;
    }
    return pending.isEmpty ? null : pending.first;
  }
}

/// One app as its owner thinks of it: the same bundle id on every store it is
/// on.
class StoreAppGroup {
  const StoreAppGroup({required this.bundleId, required this.entries});

  final String bundleId;

  /// App Store first, then Google Play.
  final List<StoreEntry> entries;

  String get name => entries.first.app.name;

  bool get needsAttention =>
      entries.any((entry) => entry.pending?.state.needsAttention ?? false);

  bool get inFlight =>
      entries.any((entry) => entry.pending?.state.inFlight ?? false);
}

/// [apps] as one group per bundle id: those needing attention first, then
/// those with a release in flight, then by name.
List<StoreAppGroup> groupStoreApps(
  Iterable<StoreApp> apps,
  Map<StoreApp, StoreAppSnapshot> snapshots,
) {
  final byBundle = <String, List<StoreEntry>>{};
  for (final app in {...apps}) {
    byBundle
        .putIfAbsent(app.bundleId, () => [])
        .add(StoreEntry(app, snapshots[app]));
  }
  int rank(StoreAppGroup group) => group.needsAttention
      ? 0
      : group.inFlight
      ? 1
      : 2;
  return [
    for (final MapEntry(:key, :value) in byBundle.entries)
      StoreAppGroup(
        bundleId: key,
        entries: value
          ..sort((a, b) => a.app.store.index.compareTo(b.app.store.index)),
      ),
  ]..sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.bundleId.compareTo(b.bundleId);
  });
}

/// Every app the server knows of: what the stores list now, and what was
/// read before from a store that is not answering.
List<StoreAppGroup> groupStoreView(
  Map<StoreKind, Reading<List<StoreApp>>> stores,
  List<StoreAppSnapshot> apps,
) => groupStoreApps(
  [
    for (final reading in stores.values) ...?reading.valueOrNull,
    for (final snapshot in apps) snapshot.app,
  ],
  {for (final snapshot in apps) snapshot.app: snapshot},
);
