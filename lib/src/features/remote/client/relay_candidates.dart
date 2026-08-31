/// The relays one paired host can be met at, and how the phone chooses
/// between them.
///
/// **A relay is a meeting place, never an identity.** The rendezvous both ends
/// use is HKDF-derived from the device key ([rendezvousFor]), not from the
/// relay URL, and every frame is sealed under that same key. So trying several
/// relays is safe: a wrong — or hostile — relay simply has nobody at the
/// rendezvous, and cannot impersonate the host because it holds no key. That
/// property is what this file rests on, and nothing here may ever let a relay
/// URL feed identity, key derivation or trust.
library;

/// Guards against a runaway list: a host that announced nonsense, or a QR
/// carrying a hundred relays, must not turn a reconnect into a phone book.
/// The HEAD is kept, because every list here is already in priority order —
/// the relay in hand first, then the host's own announcement order — so a
/// truncation drops the least useful tail and never the address being used.
const int kMaxRelayCandidates = 6;

/// How long a relay that just refused a phone is left alone. Mirrors the LAN
/// scout's grudge (`kLanRetryCooldown`) so the two paths forget at the same
/// rate: long enough that a phone at home stops dialling a dead internet
/// relay on every reconnect, short enough that a blip heals within minutes.
const Duration kRelayCandidateCooldown = Duration(minutes: 2);

/// One relay this phone may find its host at, with what happened last time.
class RelayCandidate {
  const RelayCandidate({
    required this.url,
    this.lastSuccessAt,
    this.lastFailureAt,
  });

  final Uri url;

  /// When a sealed session last came up through this relay, UTC. The most
  /// recent one is the "last known good" that gets dialled first.
  final DateTime? lastSuccessAt;

  /// When a dial through this relay last failed, UTC. Drives the cooldown.
  final DateTime? lastFailureAt;

  /// The identity a candidate is matched under across a refresh — the URL's
  /// own text, nothing derived from it.
  String get key => url.toString();

  bool inCooldown(DateTime now, {Duration cooldown = kRelayCandidateCooldown}) {
    final failed = lastFailureAt;
    if (failed == null) return false;
    // A relay that worked since it failed is not cooling any more.
    final ok = lastSuccessAt;
    if (ok != null && !ok.isBefore(failed)) return false;
    return now.toUtc().difference(failed) < cooldown;
  }

  RelayCandidate succeededAt(DateTime at) =>
      RelayCandidate(url: url, lastSuccessAt: at.toUtc(), lastFailureAt: null);

  RelayCandidate failedAt(DateTime at) => RelayCandidate(
    url: url,
    lastSuccessAt: lastSuccessAt,
    lastFailureAt: at.toUtc(),
  );

  Map<String, Object?> toJson() => {
    'url': url.toString(),
    if (lastSuccessAt != null) 'okAt': lastSuccessAt!.toIso8601String(),
    if (lastFailureAt != null) 'failAt': lastFailureAt!.toIso8601String(),
  };

  /// One stored row, or null when it names no usable relay — a corrupt entry
  /// costs its own candidate and nothing else.
  static RelayCandidate? tryFromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final url = json['url'];
    if (url is! String) return null;
    final parsed = Uri.tryParse(url);
    if (parsed == null || !parsed.hasScheme) return null;
    DateTime? at(Object? value) =>
        value is String ? DateTime.tryParse(value)?.toUtc() : null;
    return RelayCandidate(
      url: parsed,
      lastSuccessAt: at(json['okAt']),
      lastFailureAt: at(json['failAt']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RelayCandidate &&
      other.key == key &&
      other.lastSuccessAt == lastSuccessAt &&
      other.lastFailureAt == lastFailureAt;

  @override
  int get hashCode => Object.hash(key, lastSuccessAt, lastFailureAt);

  @override
  String toString() => 'RelayCandidate($url)';
}

/// The order a reconnect dials relays in: last known good first, then the rest
/// of the saved set in the order it was learned, then [fallback] — the app's
/// configured default hosted relay — as a last resort.
///
/// Candidates cooling from a recent failure are dropped, so a phone at home
/// does not re-dial a dead internet relay every cycle. If that would leave
/// nothing to try, the one that failed longest ago comes back: the phone must
/// always have somewhere to go.
List<Uri> orderRelayCandidates(
  List<RelayCandidate> saved, {
  required Uri fallback,
  required DateTime now,
  Duration cooldown = kRelayCandidateCooldown,
}) {
  // Sorted with the saved position as the tie-break, so the dial sequence is
  // identical on every reconnect: `List.sort` promises nothing about equal
  // elements, and a wobbling order would make a failure impossible to read.
  final ranked = [...saved.indexed]..sort((a, b) {
    final at = a.$2.lastSuccessAt;
    final bt = b.$2.lastSuccessAt;
    if (at == null && bt == null) return a.$1.compareTo(b.$1);
    if (at == null) return 1;
    if (bt == null) return -1;
    final byRecency = bt.compareTo(at);
    return byRecency != 0 ? byRecency : a.$1.compareTo(b.$1);
  });
  final ordered = <String, Uri>{};
  for (final (_, candidate) in ranked) {
    if (candidate.inCooldown(now, cooldown: cooldown)) continue;
    ordered[candidate.key] = candidate.url;
  }
  final savedKeys = {for (final candidate in saved) candidate.key};
  if (!savedKeys.contains(fallback.toString())) {
    ordered[fallback.toString()] = fallback;
  }
  if (ordered.isEmpty) {
    // Everything is cooling (and the fallback is one of them): try whichever
    // has been quiet longest rather than sitting here paired and unreachable.
    RelayCandidate? oldest;
    for (final candidate in saved) {
      final at = candidate.lastFailureAt;
      final best = oldest?.lastFailureAt;
      if (at == null) continue;
      if (oldest == null || best == null || at.isBefore(best)) {
        oldest = candidate;
      }
    }
    final pick = oldest ?? (saved.isEmpty ? null : saved.first);
    if (pick != null) ordered[pick.key] = pick.url;
  }
  return List.unmodifiable(ordered.values);
}

/// Folds the relay set a host just announced into what this phone has saved.
///
/// The announcement is the truth about where the host listens *now*, so it
/// replaces the set — that is how a DHCP move retires a stale
/// `ws://<old-ip>:<port>` and how a hosted relay switched on last month
/// arrives. Health carries over for URLs that survive, so a candidate does not
/// forget it works every time the host says hello. An EMPTY announcement
/// changes nothing: a host mid-restart must not strand a paired phone.
List<RelayCandidate> mergeRelayCandidates(
  List<RelayCandidate> saved,
  List<Uri> announced,
) {
  if (announced.isEmpty) return saved;
  final health = {for (final candidate in saved) candidate.key: candidate};
  final merged = <String, RelayCandidate>{};
  for (final url in announced) {
    final key = url.toString();
    merged[key] = health[key] ?? RelayCandidate(url: url);
  }
  return _capped(merged.values.toList());
}

List<RelayCandidate> _capped(List<RelayCandidate> list) =>
    list.length <= kMaxRelayCandidates
    ? List.unmodifiable(list)
    : List.unmodifiable(list.take(kMaxRelayCandidates));

/// The candidate set a payload's relay list becomes: de-duplicated, [primary]
/// first, and never empty.
List<RelayCandidate> candidatesFrom(Uri primary, List<Uri> others) {
  final urls = <String, Uri>{primary.toString(): primary};
  for (final url in others) {
    urls[url.toString()] = url;
  }
  return _capped([for (final url in urls.values) RelayCandidate(url: url)]);
}

/// Reads the `relays` array a payload or a stored record carries: strings that
/// parse into absolute URLs, in order, de-duplicated. Anything else is
/// skipped — a garbled entry costs its own relay, never the list.
List<Uri> relayUrisFrom(Object? json) {
  if (json is! List) return const [];
  final urls = <String, Uri>{};
  for (final entry in json) {
    if (entry is! String) continue;
    final parsed = Uri.tryParse(entry);
    if (parsed == null || !parsed.hasScheme) continue;
    urls[parsed.toString()] = parsed;
  }
  return List.unmodifiable(urls.values);
}

/// A `host:port` LAN hint as the host announced it, or null when it is not one.
///
/// A discovery hint only — it may be stale the moment DHCP moves, and proving
/// who answers there is still the sealed hello's job. Loopback is refused: a
/// phone dialling 127.0.0.1 would be dialling itself.
({String host, int port})? parseLanHint(String? hint) {
  if (hint == null || hint.isEmpty) return null;
  final colon = hint.lastIndexOf(':');
  if (colon <= 0 || colon == hint.length - 1) return null;
  final host = hint.substring(0, colon);
  final port = int.tryParse(hint.substring(colon + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  if (host == '127.0.0.1' || host == 'localhost' || host == '::1') return null;
  return (host: host, port: port);
}

