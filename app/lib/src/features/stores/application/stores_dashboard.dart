import 'package:riverpod/riverpod.dart';
import 'package:store_console/store_console.dart';

import '../../../core/paths/app_support_directory.dart';
import '../../../core/util/clock_provider.dart';
import '../data/store_snapshot_store.dart';
import 'store_credentials.dart';

/// A snapshot older than this is read again when the tab opens.
const Duration kStoreSnapshotMaxAge = Duration(minutes: 30);

/// How many apps are read at once: enough to finish soon, few enough that a
/// store's rate limit is not the first thing a refresh meets.
const int kStoreRefreshConcurrency = 4;

final storeSnapshotStoreProvider = Provider<StoreSnapshotStore>(
  (ref) => StoreSnapshotStore(appSupportDirectory),
);

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

/// What the Stores tab draws.
class StoresDashboard {
  const StoresDashboard({
    this.stores = const {},
    this.snapshots = const {},
    this.refreshedAt,
    this.refreshing = false,
    this.done = 0,
    this.total = 0,
  });

  /// What each connected store said when asked for its apps; a store that
  /// failed says why.
  final Map<StoreKind, Reading<List<StoreApp>>> stores;

  final Map<StoreApp, StoreAppSnapshot> snapshots;

  /// When the data shown was read from the stores — from the kept file until
  /// a refresh lands. Null when nothing has been read.
  final DateTime? refreshedAt;

  final bool refreshing;

  /// Apps read so far in the refresh under way, of [total].
  final int done;
  final int total;

  /// Every app known: what the stores list now, and what was read before from
  /// a store that is not answering.
  List<StoreAppGroup> get groups => groupStoreApps([
    for (final reading in stores.values) ...?reading.valueOrNull,
    ...snapshots.keys,
  ], snapshots);

  StoresDashboard copyWith({
    Map<StoreKind, Reading<List<StoreApp>>>? stores,
    Map<StoreApp, StoreAppSnapshot>? snapshots,
    DateTime? refreshedAt,
    bool? refreshing,
    int? done,
    int? total,
  }) => StoresDashboard(
    stores: stores ?? this.stores,
    snapshots: snapshots ?? this.snapshots,
    refreshedAt: refreshedAt ?? this.refreshedAt,
    refreshing: refreshing ?? this.refreshing,
    done: done ?? this.done,
    total: total ?? this.total,
  );
}

/// The dashboard: the kept snapshot at once; the stores themselves when the
/// tab opens on a stale one or the user asks. Never on a timer (PROJECT.md
/// §19), and never for being watched — Settings reads it too.
class StoresDashboardController extends AsyncNotifier<StoresDashboard> {
  /// Names one build, so a refresh begun for credentials since replaced stops
  /// writing.
  Object? _build;

  @override
  Future<StoresDashboard> build() async {
    _build = Object();
    final file = ref.watch(storeSnapshotStoreProvider);
    final credentials = await ref.watch(storeCredentialsProvider.future);
    final connected = credentials.connected;
    if (connected.isEmpty) return const StoresDashboard();
    final kept = await file.read();
    // A store whose credential was removed leaves the screen with it.
    final apps = [
      for (final snapshot in kept?.apps ?? const <StoreAppSnapshot>[])
        if (connected.contains(snapshot.app.store)) snapshot,
    ];
    final dashboard = kept == null
        ? const StoresDashboard()
        : StoresDashboard(
            stores: {
              for (final store in connected)
                if (apps.any((snapshot) => snapshot.app.store == store))
                  store: ReadingValue([
                    for (final snapshot in apps)
                      if (snapshot.app.store == store) snapshot.app,
                  ], kept.savedAt),
            },
            snapshots: {for (final snapshot in apps) snapshot.app: snapshot},
            refreshedAt: kept.savedAt,
          );
    return dashboard;
  }

  /// Reads the stores when nothing was kept or it is older than
  /// [kStoreSnapshotMaxAge]. What the tab calls each time it opens.
  Future<void> refreshIfStale() async {
    if (!ref.mounted) return;
    final current = await future;
    if (!ref.mounted || current.refreshing) return;
    final at = current.refreshedAt;
    final now = ref.read(clockProvider).nowUtc();
    if (at != null && now.difference(at) <= kStoreSnapshotMaxAge) return;
    await refresh();
  }

  /// Lists each store's apps, reads each app with at most
  /// [kStoreRefreshConcurrency] in flight, and keeps the result.
  Future<void> refresh() async {
    final build = _build;
    bool live() => ref.mounted && identical(build, _build);
    final current = await future;
    if (!live() || current.refreshing) return;
    final credentials = await ref.read(storeCredentialsProvider.future);
    if (!live() || credentials.isEmpty) return;
    final console = ref.read(storeConsoleProvider);
    final clock = ref.read(clockProvider);
    final file = ref.read(storeSnapshotStoreProvider);

    var dashboard = current.copyWith(refreshing: true, done: 0, total: 0);
    void publish(StoresDashboard next) {
      dashboard = next;
      state = AsyncData(next);
    }

    publish(dashboard);
    try {
      final listed = await console.listApps();
      if (!live()) return;
      final stores = {
        for (final reading in listed) reading.store: reading.apps,
      };
      final answered = {
        for (final MapEntry(:key, :value) in stores.entries)
          if (value is ReadingValue) key,
      };
      final apps = [
        for (final reading in stores.values) ...?reading.valueOrNull,
      ];
      publish(
        dashboard.copyWith(
          stores: stores,
          // An app a store no longer lists goes; one from a store that did
          // not answer stays as it was last read.
          snapshots: {
            for (final MapEntry(:key, :value) in dashboard.snapshots.entries)
              if (!answered.contains(key.store) || apps.contains(key))
                key: value,
          },
          total: apps.length,
        ),
      );

      final queue = apps.iterator;
      Future<void> worker() async {
        while (live() && queue.moveNext()) {
          final app = queue.current;
          StoreAppSnapshot? snapshot;
          try {
            snapshot = await console.snapshot(app);
          } on Object {
            // A console closed under it: the app keeps what it had.
          }
          if (!live()) return;
          publish(
            dashboard.copyWith(
              snapshots: {...dashboard.snapshots, app: ?snapshot},
              done: dashboard.done + 1,
            ),
          );
        }
      }

      await Future.wait([
        for (var i = 0; i < kStoreRefreshConcurrency; i++) worker(),
      ]);
      if (!live()) return;
      // Nothing answered: what is shown is as old as it was.
      if (answered.isEmpty) return;
      final now = clock.nowUtc();
      publish(dashboard.copyWith(refreshedAt: now));
      try {
        await file.write(
          StoreSnapshotFile(
            savedAt: now,
            apps: dashboard.snapshots.values.toList(),
          ),
        );
      } on Object {
        // Not kept: the next open reads the stores again.
      }
    } finally {
      if (live()) publish(dashboard.copyWith(refreshing: false));
    }
  }
}

final storesDashboardProvider =
    AsyncNotifierProvider<StoresDashboardController, StoresDashboard>(
      StoresDashboardController.new,
    );
