import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:store_console/store_console.dart';

/// How long the store page, and then the image, may take each. Short: an
/// icon is never worth holding a refresh up for.
const Duration playIconTimeout = Duration(seconds: 10);

/// The store page is about 1.2 MB, with the icon's tag a megabyte in
/// (2026-10-01); a page past this is not read further.
const int _maxPageBytes = 4 * 1024 * 1024;
const int _maxImageBytes = 512 * 1024;

const String _iconHost = 'play-lh.googleusercontent.com';

/// A published app's icon, from its public Play page — the Android Publisher
/// API has the icon only inside an edit, and opening an edit would break one
/// a release pipeline has open under the same account. Null when the app has
/// no public page (not yet published, or a draft). [client] must be a plain
/// transport: nothing it sends may carry the account's token.
Future<StoreIconImage?> playIcon(
  http.Client client,
  String packageName, {
  int size = 128,
}) async => (await playListing(client, packageName, size: size))?.icon;

/// What a published app's public Play page says, in one read of it: the icon,
/// as [playIcon] has it, and the install band the page shows. Null when the
/// app has no public page.
Future<StoreListing?> playListing(
  http.Client client,
  String packageName, {
  int size = 128,
}) async {
  final page = await _fetch(
    client,
    Uri.https('play.google.com', '/store/apps/details', {
      'id': packageName,
      'hl': 'en',
    }),
    maxBytes: _maxPageBytes,
    what: 'its store page',
  );
  if (page == null) return null;
  final html = utf8.decode(page.bytes, allowMalformed: true);
  final band = playInstallBand(html);
  final source = playIconUrl(html, size: size);
  if (source == null) return StoreListing(installBand: band);
  final image = await _fetch(
    client,
    source,
    maxBytes: _maxImageBytes,
    what: 'its icon',
  );
  if (image == null) return StoreListing(installBand: band);
  final type = image.contentType;
  if (!type.startsWith('image/')) {
    throw const StoreException(
      StoreFailure.shape,
      'Google Play answered the icon with something other than an image.',
    );
  }
  return StoreListing(
    icon: StoreIconImage(source: source, bytes: image.bytes, contentType: type),
    installBand: band,
  );
}

final _bandText = RegExp(r'>\s*([0-9][0-9.,]*\s*[KMB]?\+)\s*<');
final _bandData = RegExp(
  r'\["[0-9][0-9,]*\+",\d+,\d+,"([0-9][0-9.]*[KMB]?\+)"\]',
);

/// How far before the word "Downloads" its figure may sit in the page.
const int _bandReach = 400;

/// The install band an English Play page shows, `10K+`: the figure just
/// before the word "Downloads", else the short form in the page's data.
/// Null when neither is there, or is not a band [installBandFloor] reads —
/// a page in another language, or one Google has reshaped.
String? playInstallBand(String html) {
  String? valid(String? band) {
    final trimmed = band?.replaceAll(RegExp(r'\s+'), '');
    return trimmed != null && installBandFloor(trimmed) != null
        ? trimmed
        : null;
  }

  for (final label in RegExp(r'>\s*Downloads\s*<').allMatches(html)) {
    final from = label.start > _bandReach ? label.start - _bandReach : 0;
    final before = html.substring(from, label.start + 1);
    final figures = _bandText.allMatches(before).toList();
    if (figures.isEmpty) continue;
    if (valid(figures.last.group(1)) case final band?) return band;
  }
  return valid(_bandData.firstMatch(html)?.group(1));
}

final _ogImage = RegExp(
  r'''<meta[^>]+property=["']og:image["'][^>]*>''',
  caseSensitive: false,
);
final _content = RegExp(r'''content=["']([^"']+)["']''', caseSensitive: false);
final _anyIcon = RegExp(r'https://play-lh\.googleusercontent\.com/[\w-]+');

/// The icon a Play store page names, sized to [size] px: its `og:image`, else
/// the first image on Google's Play image host. Null when the page names
/// none on that host.
Uri? playIconUrl(String html, {int size = 128}) {
  String? found;
  final meta = _ogImage.firstMatch(html)?.group(0);
  if (meta != null) {
    found = _content
        .firstMatch(meta)
        ?.group(1)
        ?.replaceAll('&amp;', '&')
        .trim();
  }
  var uri = found == null ? null : Uri.tryParse(found);
  if (uri == null || uri.host != _iconHost) {
    final any = _anyIcon.firstMatch(html)?.group(0);
    uri = any == null ? null : Uri.tryParse(any);
  }
  if (uri == null || uri.host != _iconHost || uri.scheme != 'https') {
    return null;
  }
  // The image host sizes by a suffix after `=`: `=s0-br30` is the original,
  // `=s128` a 128 px square PNG.
  final path = uri.path;
  final cut = path.indexOf('=');
  final base = cut < 0 ? path : path.substring(0, cut);
  if (base.length < 2) return null;
  return Uri.https(_iconHost, '$base=s$size');
}

typedef _Fetched = ({Uint8List bytes, String contentType});

/// Null on a 404 or 410: the thing is not public.
Future<_Fetched?> _fetch(
  http.Client client,
  Uri uri, {
  required int maxBytes,
  required String what,
}) async {
  try {
    final request = http.Request('GET', uri)
      ..followRedirects = true
      ..headers['Accept-Language'] = 'en';
    final response = await client.send(request).timeout(playIconTimeout);
    final status = response.statusCode;
    if (status == 404 || status == 410) {
      unawaited(response.stream.drain<void>().catchError((Object _) {}));
      return null;
    }
    if (status < 200 || status >= 300) {
      unawaited(response.stream.drain<void>().catchError((Object _) {}));
      throw StoreException(
        status >= 500 ? StoreFailure.server : StoreFailure.network,
        'Google Play did not give $what (HTTP $status).',
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(playIconTimeout)) {
      builder.add(chunk);
      if (builder.length > maxBytes) break;
    }
    final type = (response.headers['content-type'] ?? '')
        .split(';')
        .first
        .trim()
        .toLowerCase();
    return (bytes: builder.takeBytes(), contentType: type);
  } on StoreException {
    rethrow;
  } on TimeoutException {
    throw StoreException(
      StoreFailure.network,
      'Google Play did not give $what within '
      '${playIconTimeout.inSeconds} seconds.',
    );
  } on Exception {
    // The error's text can carry the URL; it says nothing secret, but the
    // other failures are worded without it too.
    throw StoreException(
      StoreFailure.network,
      'Google Play could not be reached for $what.',
    );
  }
}
