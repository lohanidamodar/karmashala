/// How the session host serves phones: what its `server.json` says — which
/// the desktop's Remote access settings write — plus, while the server's own
/// LAN relay runs, where it can be dialled.
class CompanionConfig {
  const CompanionConfig({
    required this.enabled,
    this.relay,
    this.hostedEnabled = true,
    this.localRelayUrl,
    this.extraRelays = const [],
    this.notesEnabled = true,
    this.advertise = false,
  });

  /// Remote access off: nothing listens.
  static const CompanionConfig off = CompanionConfig(enabled: false);

  /// Whether remote access is on at all. Off, nothing listens.
  final bool enabled;

  /// The hosted relay a row falls back to and a pairing defaults to, or null
  /// for none.
  final Uri? relay;

  /// Whether the hosted relay is switched on.
  final bool hostedEnabled;

  /// Where the server's own LAN relay can be dialled while it runs. Never
  /// kept: read off the running relay.
  final Uri? localRelayUrl;

  /// Relays on the person's own SSH hosts.
  final List<Uri> extraRelays;

  /// Whether Notes is switched on; off, `notes.get` says so and sends none.
  final bool notesEnabled;

  /// Whether to announce this machine on the LAN beacon. A desktop's phones
  /// find it that way; a box has no business multicasting.
  final bool advertise;

  /// The same config with the local relay at [url], or none.
  CompanionConfig withLocalRelay(Uri? url) => CompanionConfig(
    enabled: enabled,
    relay: relay,
    hostedEnabled: hostedEnabled,
    localRelayUrl: url,
    extraRelays: extraRelays,
    notesEnabled: notesEnabled,
    advertise: advertise,
  );

  /// Whether serving under [other] needs the server started again: its default
  /// relay and its beacon are fixed for a server's life.
  bool restartsFor(CompanionConfig other) =>
      other.enabled != enabled ||
      other.relay?.toString() != relay?.toString() ||
      other.advertise != advertise;

  @override
  bool operator ==(Object other) =>
      other is CompanionConfig &&
      other.enabled == enabled &&
      other.relay?.toString() == relay?.toString() &&
      other.hostedEnabled == hostedEnabled &&
      other.localRelayUrl?.toString() == localRelayUrl?.toString() &&
      _sameUris(other.extraRelays, extraRelays) &&
      other.notesEnabled == notesEnabled &&
      other.advertise == advertise;

  @override
  int get hashCode => Object.hash(
    enabled,
    relay?.toString(),
    hostedEnabled,
    localRelayUrl?.toString(),
    Object.hashAll(extraRelays.map((uri) => uri.toString())),
    notesEnabled,
    advertise,
  );

  static bool _sameUris(List<Uri> a, List<Uri> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].toString() != b[i].toString()) return false;
    }
    return true;
  }
}
