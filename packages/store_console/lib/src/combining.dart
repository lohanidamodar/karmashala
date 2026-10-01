/// Which apps on different stores are one app as their owner thinks of it.
library;

import 'domain.dart';

/// An App Store app and a Google Play app their owner has said are the same
/// app, though their bundle id and package name differ.
class StoreAppLink {
  const StoreAppLink({required this.appStoreId, required this.packageName});

  /// The App Store app's numeric id: its [StoreApp.id] there.
  final String appStoreId;

  /// The Play app's package name: its [StoreApp.id] there.
  final String packageName;

  /// Whether [app] is one of the two.
  bool includes(StoreApp app) => switch (app.store) {
    StoreKind.appStore => app.id == appStoreId,
    StoreKind.googlePlay => app.id == packageName,
  };

  Map<String, Object?> toJson() => {
    'appStoreId': appStoreId,
    'packageName': packageName,
  };

  factory StoreAppLink.fromJson(Map<String, Object?> json) => StoreAppLink(
    appStoreId: json['appStoreId']! as String,
    packageName: json['packageName']! as String,
  );

  @override
  bool operator ==(Object other) =>
      other is StoreAppLink &&
      other.appStoreId == appStoreId &&
      other.packageName == packageName;

  @override
  int get hashCode => Object.hash(appStoreId, packageName);
}

/// How the apps in a [StoreAppCombination] came to be together.
enum StoreCombined {
  /// One app on one store: nothing combined.
  alone,

  /// The same bundle id or package name on each store.
  byId,

  /// A [StoreAppLink] its owner made.
  manually,
}

/// The apps that are one app as their owner thinks of it.
class StoreAppCombination {
  const StoreAppCombination(this.apps, this.combined);

  /// App Store first, then Google Play.
  final List<StoreApp> apps;
  final StoreCombined combined;

  /// The bundle id it is known by: the first app's.
  String get bundleId => apps.first.bundleId;
}

/// [apps] as the app each one is part of. A [StoreAppLink] whose two apps
/// are both among [apps] puts them together, whatever their ids; every other
/// app joins those with its bundle id. So an app linked by hand leaves the
/// app its id would have matched standing alone. A link naming an app absent
/// from [apps] is ignored, and an app in two links stays in the first.
///
/// In the order each combination's first app comes in [apps], links first;
/// the caller sorts.
List<StoreAppCombination> combineStoreApps(
  Iterable<StoreApp> apps, {
  Iterable<StoreAppLink> links = const [],
}) {
  final unique = {...apps};
  StoreApp? find(StoreKind store, String id) {
    for (final app in unique) {
      if (app.store == store && app.id == id) return app;
    }
    return null;
  }

  final taken = <StoreApp>{};
  final combinations = <StoreAppCombination>[];
  for (final link in links) {
    final apple = find(StoreKind.appStore, link.appStoreId);
    final play = find(StoreKind.googlePlay, link.packageName);
    if (apple == null || play == null) continue;
    if (taken.contains(apple) || taken.contains(play)) continue;
    taken
      ..add(apple)
      ..add(play);
    combinations.add(
      StoreAppCombination([apple, play], StoreCombined.manually),
    );
  }

  final byBundle = <String, List<StoreApp>>{};
  for (final app in unique) {
    if (taken.contains(app)) continue;
    byBundle.putIfAbsent(app.bundleId, () => []).add(app);
  }
  for (final group in byBundle.values) {
    group.sort((a, b) => a.store.index.compareTo(b.store.index));
    combinations.add(
      StoreAppCombination(
        group,
        group.length > 1 ? StoreCombined.byId : StoreCombined.alone,
      ),
    );
  }
  return combinations;
}
