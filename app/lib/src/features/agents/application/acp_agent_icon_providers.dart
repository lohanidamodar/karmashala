import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import '../../../core/paths/app_support_directory.dart';
import 'acp_agent_providers.dart' show acpRegistryHttpClientProvider;

/// Where fetched agent icons are kept, under the app's data folder; a test
/// points it at a scratch folder.
final acpAgentIconCacheDirectoryProvider = FutureProvider<Directory>(
  (ref) async =>
      Directory(p.join((await appSupportDirectory()).path, 'acp-icons')),
);

/// The SVG text at [url] — an ACP agent's icon as the public registry
/// publishes it — read from the on-disk cache, else fetched once and kept
/// there. Null when it could not be had: the glyph stands in, and once
/// nothing draws it any more the next look asks again.
final acpAgentIconProvider = FutureProvider.autoDispose.family<String?, String>(
  (ref, url) async {
    final directory = await ref.watch(
      acpAgentIconCacheDirectoryProvider.future,
    );
    final file = File(p.join(directory.path, iconCacheFileName(url)));
    try {
      if (await file.exists()) return _asSvg(await file.readAsString());
    } on IOException {
      // Unreadable cache: fetch again below.
    }
    final svg = await _fetch(ref, url);
    if (svg == null) return null;
    try {
      await directory.create(recursive: true);
      await file.writeAsString(svg);
    } on IOException {
      // Nothing cached; drawn this once from memory.
    }
    return svg;
  },
);

/// The cache file for [url]: its last path segment, kept to safe characters,
/// behind a hash of the whole URL so two registries' `x.svg` cannot collide.
String iconCacheFileName(String url) {
  final name = (Uri.tryParse(url)?.pathSegments.lastOrNull ?? 'icon')
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final base = name.endsWith('.svg')
      ? name.substring(0, name.length - 4)
      : name;
  return '${_fnv1a(url).toRadixString(16).padLeft(8, '0')}-$base.svg';
}

// FNV-1a over the URL's UTF-8: stable across runs, no package needed.
int _fnv1a(String text) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(text)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// Only an SVG document is drawn; anything else the CDN answers with — an
/// HTML error page, say — reads as no icon.
String? _asSvg(String text) => text.contains('<svg') ? text : null;

Future<String?> _fetch(Ref ref, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return null;
  final client = ref.read(acpRegistryHttpClientProvider)();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 15));
    final body = await response.transform(utf8.decoder).join();
    return response.statusCode == HttpStatus.ok ? _asSvg(body) : null;
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}
