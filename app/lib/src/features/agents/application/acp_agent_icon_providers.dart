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

/// How long a failed fetch is remembered before it is tried again while
/// something still draws the agent; a test shortens it.
final acpAgentIconRetryDelayProvider = Provider<Duration>(
  (ref) => const Duration(minutes: 2),
);

/// The SVG text at [url] — an ACP agent's icon as the public registry
/// publishes it — read from the on-disk cache, else fetched once and kept
/// there. Null when it could not be had: the glyph stands in, and it is
/// asked for again after [acpAgentIconRetryDelayProvider] while drawn, or
/// at once the next time it is drawn after nothing drew it.
final acpAgentIconProvider = FutureProvider.autoDispose.family<String?, String>(
  (ref, url) async {
    // Read before any await: a provider let go of mid-fetch has a dead ref.
    final newClient = ref.read(acpRegistryHttpClientProvider);
    final retryAfter = ref.read(acpAgentIconRetryDelayProvider);
    final directory = await ref.watch(
      acpAgentIconCacheDirectoryProvider.future,
    );
    final file = File(p.join(directory.path, iconCacheFileName(url)));
    try {
      if (await file.exists()) {
        final cached = asSvgDocument(await file.readAsString());
        if (cached != null) return cached;
        // Something that is not an SVG was kept by an older build: fetched
        // again below, and the file replaced or removed.
      }
    } on IOException {
      // Unreadable cache: fetch again below.
    }
    final svg = await _fetch(newClient, url);
    if (svg == null) {
      if (ref.mounted) {
        final retry = Timer(retryAfter, ref.invalidateSelf);
        ref.onDispose(retry.cancel);
      }
      try {
        if (await file.exists()) await file.delete();
      } on IOException {
        // Left for the next look.
      }
      return null;
    }
    // Written beside and renamed over, so a reader never sees half an icon.
    final partial = File('${file.path}.partial');
    try {
      await directory.create(recursive: true);
      await partial.writeAsString(svg, flush: true);
      await partial.rename(file.path);
    } on IOException {
      // Nothing cached; drawn this once from memory.
      try {
        if (await partial.exists()) await partial.delete();
      } on IOException {
        // Left for the next write to replace.
      }
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

/// [text] when it is an SVG document — one whose root element is `<svg>`,
/// after any XML prolog, doctype or comment — else null. A CDN's "not
/// found" page is HTML that happens to hold an inline `<svg>`, which is why
/// containing the tag is not enough.
String? asSvgDocument(String text) {
  var rest = text.trimLeft();
  if (rest.startsWith('﻿')) rest = rest.substring(1);
  while (true) {
    if (rest.startsWith('<?')) {
      final end = rest.indexOf('?>');
      if (end < 0) return null;
      rest = rest.substring(end + 2).trimLeft();
    } else if (rest.startsWith('<!--')) {
      final end = rest.indexOf('-->');
      if (end < 0) return null;
      rest = rest.substring(end + 3).trimLeft();
    } else if (rest.startsWith('<!')) {
      final end = rest.indexOf('>');
      if (end < 0) return null;
      rest = rest.substring(end + 1).trimLeft();
    } else {
      break;
    }
  }
  return RegExp(r'^<svg[\s/>]').hasMatch(rest) ? text : null;
}

Future<String?> _fetch(HttpClient Function() newClient, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return null;
  final client = newClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 15));
    final body = await response.transform(utf8.decoder).join();
    return response.statusCode == HttpStatus.ok ? asSvgDocument(body) : null;
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}
