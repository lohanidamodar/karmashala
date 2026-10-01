import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show StoreAppIcon;
import 'package:store_console/store_console.dart';

/// One app on one store, with what was read about it — null until it has
/// been read.
class StoreEntry {
  const StoreEntry(this.app, this.snapshot, {this.icon});

  final StoreApp app;
  final StoreAppSnapshot? snapshot;

  /// Its icon as the server keeps it; null when never looked up.
  final StoreAppIcon? icon;

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
/// on, or two apps its owner combined by hand ([combined]).
class StoreAppGroup {
  const StoreAppGroup({
    required this.bundleId,
    required this.entries,
    this.combined = StoreCombined.alone,
  });

  /// The first entry's bundle id; a group combined by hand may have another
  /// on its other store — [bundleIds] has both.
  final String bundleId;

  /// App Store first, then Google Play.
  final List<StoreEntry> entries;

  /// How the entries came to be one app.
  final StoreCombined combined;

  bool get combinedManually => combined == StoreCombined.manually;

  /// Each distinct bundle id or package name, App Store first: one unless
  /// combined by hand.
  List<String> get bundleIds => [
    ...{for (final entry in entries) entry.app.bundleId},
  ];

  /// Unique among groups however they are combined: its first app's
  /// [StoreApp.key].
  String get key => entries.first.app.key;

  /// Whether the app with [appKey] — a [StoreApp.key] — is in this group.
  bool has(String? appKey) => entries.any((entry) => entry.app.key == appKey);

  /// The one store this app is on, or null when it is on both.
  StoreKind? get onlyStore =>
      entries.length == 1 ? entries.single.app.store : null;

  /// The pair to ask the server to separate; null unless combined by hand.
  StoreAppLink? get link {
    if (!combinedManually) return null;
    String? apple;
    String? play;
    for (final entry in entries) {
      switch (entry.app.store) {
        case StoreKind.appStore:
          apple = entry.app.id;
        case StoreKind.googlePlay:
          play = entry.app.id;
      }
    }
    if (apple == null || play == null) return null;
    return StoreAppLink(appStoreId: apple, packageName: play);
  }

  String get name => entries.first.app.name;

  /// The server's copy of the app's icon: the App Store's, else Google
  /// Play's. Null when neither store has a public page for it, or it has not
  /// been looked up yet.
  StoreAppIcon? get icon {
    for (final entry in entries) {
      final icon = entry.icon;
      if (icon?.path != null) return icon;
    }
    return null;
  }

  bool get needsAttention =>
      entries.any((entry) => entry.pending?.state.needsAttention ?? false);

  bool get inFlight =>
      entries.any((entry) => entry.pending?.state.inFlight ?? false);
}

/// [apps] as one group per app as [combineStoreApps] — the agent tools'
/// grouping too — combines them, [links] first: those needing attention
/// first, then those with a release in flight, then by name.
List<StoreAppGroup> groupStoreApps(
  Iterable<StoreApp> apps,
  Map<StoreApp, StoreAppSnapshot> snapshots, {
  Map<String, StoreAppIcon> icons = const {},
  Iterable<StoreAppLink> links = const [],
}) {
  int rank(StoreAppGroup group) => group.needsAttention
      ? 0
      : group.inFlight
      ? 1
      : 2;
  return [
    for (final combination in combineStoreApps(apps, links: links))
      StoreAppGroup(
        bundleId: combination.bundleId,
        combined: combination.combined,
        entries: [
          for (final app in combination.apps)
            StoreEntry(app, snapshots[app], icon: icons[app.key]),
        ],
      ),
  ]..sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (byName != 0) return byName;
    final byBundle = a.bundleId.compareTo(b.bundleId);
    return byBundle != 0 ? byBundle : a.key.compareTo(b.key);
  });
}

/// Every app the server knows of: what the stores list now, and what was
/// read before from a store that is not answering.
List<StoreAppGroup> groupStoreView(
  Map<StoreKind, Reading<List<StoreApp>>> stores,
  List<StoreAppSnapshot> apps, {
  Map<String, StoreAppIcon> icons = const {},
  Iterable<StoreAppLink> links = const [],
}) => groupStoreApps(
  [
    for (final reading in stores.values) ...?reading.valueOrNull,
    for (final snapshot in apps) snapshot.app,
  ],
  {for (final snapshot in apps) snapshot.app: snapshot},
  icons: icons,
  links: links,
);
