import 'attached_app.dart';

/// Every VM service address the app knows about right now, and when it last
/// looked for one.
///
/// **Nothing in here is persisted, on purpose.** A VM service URI dies with the
/// `flutter run` that printed it and gets a new port and a new auth token on
/// the next one, so a stored address is exactly the state §20 is about: it
/// would answer "installed" long after it stopped being true. The durable half
/// is the *directory* the addresses are discovered in; the addresses themselves
/// are re-derived every time we look.
class FlutterAppRegistry {
  const FlutterAppRegistry({
    this.apps = const <AttachedApp>[],
    this.lookedAt,
    this.discoveryDirectory,
    this.discoveryFailure,
  });

  final List<AttachedApp> apps;

  /// When discovery last ran, or `null` for **we have not looked**.
  ///
  /// The distinction this field exists for: an empty [apps] with a null
  /// [lookedAt] says nothing at all, and an empty [apps] with a timestamp says
  /// no Flutter app is running. Those are different sentences and the panel
  /// prints them differently.
  final DateTime? lookedAt;

  /// Where the runs **Karmashala starts** write their address. Reported so a
  /// reader can see what was looked at; nobody is asked to write here.
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

  /// The one app to act on when a caller named none, or `null` when the choice
  /// is not obvious.
  ///
  /// Exactly one attached app is the common case and picking it saves every
  /// caller an argument; two is ambiguous and is refused by name rather than
  /// resolved by guessing, the way `DeviceFleet.driverFor` refuses.
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
/// read.
///
/// Four sentences, and they are four because they ask for four different
/// things. This is the whole §19 contract for this feature in one function, so
/// it is a pure function with its own tests rather than four `if`s in a
/// `build()` and four more in a tool handler.
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
