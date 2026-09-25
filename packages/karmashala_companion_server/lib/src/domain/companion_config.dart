/// What the desktop's Remote access settings say about serving phones, as the
/// session host needs them: the host serves the phones, but the person
/// switches remote access on, picks relays and turns Notes off in the app.
///
/// The app sends one on every link; the host keeps it, without
/// [localRelayUrl], so it serves the same way while the app is closed.
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

  /// What a host that no app has ever configured serves by: phones only where
  /// each row says, no default relay and no beacon — a box's way.
  static const CompanionConfig unconfigured = CompanionConfig(enabled: true);

  /// Whether remote access is on at all. Off, nothing listens.
  final bool enabled;

  /// The hosted relay a row falls back to and a pairing defaults to, or null
  /// for none.
  final Uri? relay;

  /// Whether the hosted relay is switched on.
  final bool hostedEnabled;

  /// The app's embedded relay while it runs. Never kept: it is the app's own
  /// listener and closes with it.
  final Uri? localRelayUrl;

  /// Relays on the person's own SSH hosts.
  final List<Uri> extraRelays;

  /// Whether Notes is switched on; off, `notes.get` says so and sends none.
  final bool notesEnabled;

  /// Whether to announce this machine on the LAN beacon. A desktop's phones
  /// find it that way; a box has no business multicasting.
  final bool advertise;

  /// The same config with the app's own listener gone.
  CompanionConfig withoutLocalRelay() => CompanionConfig(
    enabled: enabled,
    relay: relay,
    hostedEnabled: hostedEnabled,
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

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    if (relay != null) 'relay': relay.toString(),
    'hostedEnabled': hostedEnabled,
    if (localRelayUrl != null) 'localRelayUrl': localRelayUrl.toString(),
    'extraRelays': [for (final relay in extraRelays) relay.toString()],
    'notesEnabled': notesEnabled,
    'advertise': advertise,
  };

  /// Reads what [toJson] wrote. Anything unreadable is left at its default,
  /// never guessed.
  static CompanionConfig fromJson(Map<String, Object?> json) {
    Uri? uri(Object? value) {
      if (value is! String || value.isEmpty) return null;
      final parsed = Uri.tryParse(value);
      return parsed != null && parsed.hasScheme ? parsed : null;
    }

    final extras = json['extraRelays'];
    return CompanionConfig(
      enabled: json['enabled'] != false,
      relay: uri(json['relay']),
      hostedEnabled: json['hostedEnabled'] != false,
      localRelayUrl: uri(json['localRelayUrl']),
      extraRelays: [
        for (final value in extras is List ? extras : const []) ?uri(value),
      ],
      notesEnabled: json['notesEnabled'] != false,
      advertise: json['advertise'] == true,
    );
  }

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
