import 'attached_app.dart';

/// Every VM service address the app knows about right now, and when it last
/// looked. Nothing here is persisted: a URI dies with the run that printed it,
/// so the durable half is the directory, never the address (§20).
class FlutterAppRegistry {
  const FlutterAppRegistry({
    this.apps = const <AttachedApp>[],
    this.lookedAt,
    this.discoveryDirectory,
    this.discoveryFailure,
  });

  final List<AttachedApp> apps;

  /// When discovery last ran, or `null` for **we have not looked** — which is
  /// a different sentence from "no Flutter app is running".
  final DateTime? lookedAt;

  /// Where the runs **Karmashala starts** write their address, reported so a
  /// reader can see what was looked at.
  final String? discoveryDirectory;

  /// Why discovery itself could not run — the directory could not be created
  /// or read. Not the same as finding nothing.
  final String? discoveryFailure;

  bool get hasLooked => lookedAt != null;

  Iterable<AttachedApp> get attached =>
      apps.where((app) => app.reachability == AppReachability.attached);

  AttachedApp? byId(String id) {
    for (final app in apps) {
      if (app.id == id) return app;
    }
    return null;
  }

  /// The one app to act on when a caller named none, or `null` — two attached
  /// apps are refused by name rather than resolved by guessing.
  AttachedApp? get onlyAttached {
    final live = attached.toList(growable: false);
    return live.length == 1 ? live.single : null;
  }

  FlutterAppRegistry copyWith({
    List<AttachedApp>? apps,
    DateTime? lookedAt,
    String? discoveryDirectory,
    String? discoveryFailure,
    bool clearDiscoveryFailure = false,
  }) => FlutterAppRegistry(
    apps: apps ?? this.apps,
    lookedAt: lookedAt ?? this.lookedAt,
    discoveryDirectory: discoveryDirectory ?? this.discoveryDirectory,
    discoveryFailure: clearDiscoveryFailure
        ? null
        : (discoveryFailure ?? this.discoveryFailure),
  );
}

/// The one-line state of the world, in the words the user and an agent both
/// read. Four sentences because they ask for four different things (§19).
String describeRegistry(FlutterAppRegistry registry) {
  if (registry.discoveryFailure != null) {
    return 'We could not look: ${registry.discoveryFailure}';
  }
  if (!registry.hasLooked) {
    return 'We have not looked for a running Flutter app yet.';
  }
  if (registry.apps.isEmpty) {
    return 'No Flutter app is running that we can see.';
  }
  final live = registry.attached.length;
  final stale = registry.apps.length - live;
  if (live == 0) {
    return '$stale ${stale == 1 ? 'address is' : 'addresses are'} on record '
        'and nothing answers on ${stale == 1 ? 'it' : 'any of them'}.';
  }
  final head = '$live Flutter ${live == 1 ? 'app' : 'apps'} attached';
  return stale == 0
      ? '$head.'
      : '$head, and $stale ${stale == 1 ? 'address' : 'addresses'} nothing '
            'answers on.';
}
