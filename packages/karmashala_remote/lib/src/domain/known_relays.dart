/// The relays PopupBits runs, and which of them a pairing should live on.
/// **The one place** that says which relay is the old default: everything
/// else asks [KnownRelays] rather than comparing against a literal.
library;

/// The relay official builds name in `KARMASHALA_RELAY_URL`. Pinned to every
/// build script and release workflow by test.
const String kPopupBitsRelayUrl = 'wss://kmrelay.popupbits.com';

/// Relays PopupBits ran before [kPopupBitsRelayUrl], still up for the phones
/// paired through them. A pairing on one of these is moved; nothing else is.
const List<String> kRetiredPopupBitsRelayUrls = ['wss://relay.popupbits.com'];

/// Which relay a pairing lives on, as a policy: a pairing on a [retired]
/// relay moves to [current]; one anywhere else — a self-hoster's relay, the
/// LAN — stays where it is.
class KnownRelays {
  const KnownRelays({required this.current, this.retired = const []});

  static final KnownRelays popupBits = KnownRelays(
    current: Uri.parse(kPopupBitsRelayUrl),
    retired: [for (final url in kRetiredPopupBitsRelayUrls) Uri.parse(url)],
  );

  final Uri current;
  final List<Uri> retired;

  bool isRetired(Uri url) => retired.any((old) => sameRelay(old, url));

  /// Where a pairing stored on [relayUrl] (a row's text) should move, or null
  /// when it stays.
  Uri? moveTargetFor(String? relayUrl) {
    final parsed = relayUrl == null ? null : Uri.tryParse(relayUrl);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      return null;
    }
    return isRetired(parsed) ? current : null;
  }

  /// [configured] with a retired relay read as [current]: a config saved
  /// while the old one was the default still pairs on the new one.
  Uri? upgrade(Uri? configured) =>
      configured != null && isRetired(configured) ? current : configured;
}

/// Whether [a] and [b] name one relay: scheme family, host, port and path,
/// ignoring case, a default port, a trailing slash and the query (where an
/// access token may ride).
bool sameRelay(Uri a, Uri b) {
  String key(Uri url) {
    final secure = switch (url.scheme.toLowerCase()) {
      'wss' || 'https' => true,
      _ => false,
    };
    final port = url.hasPort ? url.port : (secure ? 443 : 80);
    var path = url.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return '${secure ? 's' : ''}|${url.host.toLowerCase()}|$port|$path';
  }

  return key(a) == key(b);
}
