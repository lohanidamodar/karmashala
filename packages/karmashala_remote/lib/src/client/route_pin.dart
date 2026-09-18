/// How the phone may reach one paired desktop: by whatever answers, or by one
/// route the person chose and nothing else.
///
/// **A pin is "only", never "prefer".** A pinned route that stops answering is
/// said, with a way back to [auto] — it is never quietly swapped for another
/// route, because a person who pinned the relay on their own box did it to keep
/// the traffic off every other meeting place. Like every relay here, a pinned
/// one is a meeting place and never an identity (`relay_candidates.dart`).
library;

enum CompanionRouteKind {
  /// The phone's own order: LAN first, then the relays, last good first.
  auto,

  /// This network only — the beacon and the desktop's announced LAN address.
  lan,

  /// One relay, [CompanionRoutePin.relay], and no other.
  relay,
}

class CompanionRoutePin {
  const CompanionRoutePin._(this.kind, this.relay);

  factory CompanionRoutePin.relay(Uri url) =>
      CompanionRoutePin._(CompanionRouteKind.relay, url);

  static const CompanionRoutePin auto = CompanionRoutePin._(
    CompanionRouteKind.auto,
    null,
  );

  static const CompanionRoutePin lan = CompanionRoutePin._(
    CompanionRouteKind.lan,
    null,
  );

  final CompanionRouteKind kind;

  /// The one relay a [CompanionRouteKind.relay] pin allows; null otherwise.
  final Uri? relay;

  bool get isAuto => kind == CompanionRouteKind.auto;

  /// Null for [auto], which is written as nothing — so a record that was
  /// never pinned is byte-for-byte what an older build wrote.
  Map<String, Object?>? toJson() => switch (kind) {
    CompanionRouteKind.auto => null,
    CompanionRouteKind.lan => {'kind': 'lan'},
    CompanionRouteKind.relay => {'kind': 'relay', 'url': relay.toString()},
  };

  /// The stored pin, or [auto] for anything this build cannot read. A pin is a
  /// preference; the pairing it rides on is not, and must never be lost to it.
  static CompanionRoutePin fromJson(Object? json) {
    if (json is! Map<String, Object?>) return auto;
    switch (json['kind']) {
      case 'lan':
        return lan;
      case 'relay':
        final url = json['url'];
        final parsed = url is String ? Uri.tryParse(url) : null;
        if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
          return auto;
        }
        return CompanionRoutePin.relay(parsed);
    }
    return auto;
  }

  @override
  bool operator ==(Object other) =>
      other is CompanionRoutePin &&
      other.kind == kind &&
      other.relay?.toString() == relay?.toString();

  @override
  int get hashCode => Object.hash(kind, relay?.toString());

  @override
  String toString() => switch (kind) {
    CompanionRouteKind.auto => 'CompanionRoutePin.auto',
    CompanionRouteKind.lan => 'CompanionRoutePin.lan',
    CompanionRouteKind.relay => 'CompanionRoutePin.relay($relay)',
  };
}
