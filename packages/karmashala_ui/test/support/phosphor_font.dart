import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads one of the Phosphor fonts picons ships, so a hand-added `AppIcons`
/// codepoint is checked against the font itself rather than a copied table.
///
/// Two independent facts are read: the `cmap` (codepoint → glyph id) and the
/// GSUB ligatures (Phosphor name, e.g. `record-fill` → glyph id). A codepoint
/// is right when both land on the same glyph.
class PhosphorFont {
  PhosphorFont._(this._data);

  final ByteData _data;

  /// The font file for [family] (`PhosphorRegular`, `PhosphorFill`), resolved
  /// through the package config — the same picons the app builds against.
  /// (`Isolate.resolvePackageUri` is unsupported under `flutter test`, so the
  /// workspace's `.dart_tool/package_config.json` is read directly.)
  static PhosphorFont load(String family) => _loaded[family] ??= _read(family);

  static final _loaded = <String, PhosphorFont>{};

  static PhosphorFont _read(String family) {
    final file = switch (family) {
      'PhosphorRegular' => 'Phosphor.ttf',
      'PhosphorFill' => 'Phosphor-Fill.ttf',
      _ => throw ArgumentError.value(family, 'family'),
    };
    final bytes = File.fromUri(
      _piconsLib().resolve('fonts/$file'),
    ).readAsBytesSync();
    return PhosphorFont._(ByteData.sublistView(bytes));
  }

  static Uri _piconsLib() {
    var dir = Directory.current.absolute;
    while (true) {
      final config = File('${dir.path}/.dart_tool/package_config.json');
      if (config.existsSync()) {
        final json = jsonDecode(config.readAsStringSync()) as Map;
        final picons = (json['packages'] as List).cast<Map>().firstWhere(
          (p) => p['name'] == 'picons',
        );
        final root = config.parent.uri.resolve(picons['rootUri'] as String);
        final withSlash = root.path.endsWith('/')
            ? root
            : root.replace(path: '${root.path}/');
        return withSlash.resolve(picons['packageUri'] as String);
      }
      if (dir.parent.path == dir.path) {
        throw StateError('no .dart_tool/package_config.json above the test');
      }
      dir = dir.parent;
    }
  }

  int _u16(int at) => _data.getUint16(at);
  int _u32(int at) => _data.getUint32(at);

  int _table(String tag) {
    for (var i = 0; i < _u16(4); i++) {
      final record = 12 + 16 * i;
      final name = String.fromCharCodes([
        for (var k = 0; k < 4; k++) _data.getUint8(record + k),
      ]);
      if (name == tag) return _u32(record + 8);
    }
    throw StateError('no $tag table');
  }

  late final Map<int, int> _cmap = () {
    final cmap = _table('cmap');
    final glyphs = <int, int>{};
    for (var i = 0; i < _u16(cmap + 2); i++) {
      final at = cmap + _u32(cmap + 8 + 8 * i);
      if (_u16(at) != 4) continue;
      final segments = _u16(at + 6) ~/ 2;
      final ends = at + 14;
      final starts = ends + 2 * segments + 2;
      final deltas = starts + 2 * segments;
      final offsets = deltas + 2 * segments;
      for (var s = 0; s < segments; s++) {
        final start = _u16(starts + 2 * s);
        final delta = _data.getInt16(deltas + 2 * s);
        final offset = _u16(offsets + 2 * s);
        for (var cp = start; cp <= _u16(ends + 2 * s) && cp != 0xffff; cp++) {
          var glyph = offset == 0
              ? cp + delta
              : _u16(offsets + 2 * s + offset + 2 * (cp - start));
          if (offset != 0 && glyph != 0) glyph += delta;
          glyph &= 0xffff;
          if (glyph != 0) glyphs[cp] = glyph;
        }
      }
    }
    return glyphs;
  }();

  List<int> _coverage(int at) {
    if (_u16(at) == 1) {
      return [for (var i = 0; i < _u16(at + 2); i++) _u16(at + 4 + 2 * i)];
    }
    return [
      for (var i = 0; i < _u16(at + 2); i++)
        for (var g = _u16(at + 4 + 6 * i); g <= _u16(at + 6 + 6 * i); g++) g,
    ];
  }

  late final Map<String, int> _ligatures = () {
    final letters = {
      for (final e in _cmap.entries)
        if (e.key < 0x80) e.value: e.key,
    };
    final gsub = _table('GSUB');
    final lookups = gsub + _u16(gsub + 8);
    final found = <String, int>{};
    for (var l = 0; l < _u16(lookups); l++) {
      final lookup = lookups + _u16(lookups + 2 + 2 * l);
      if (_u16(lookup) != 4) continue;
      for (var s = 0; s < _u16(lookup + 4); s++) {
        final sub = lookup + _u16(lookup + 6 + 2 * s);
        final firsts = _coverage(sub + _u16(sub + 2));
        for (var i = 0; i < _u16(sub + 4); i++) {
          final set = sub + _u16(sub + 6 + 2 * i);
          for (var j = 0; j < _u16(set); j++) {
            final ligature = set + _u16(set + 2 + 2 * j);
            final ids = [
              firsts[i],
              for (var k = 0; k < _u16(ligature + 2) - 1; k++)
                _u16(ligature + 4 + 2 * k),
            ];
            if (!ids.every(letters.containsKey)) continue;
            found[String.fromCharCodes(ids.map((id) => letters[id]!))] = _u16(
              ligature,
            );
          }
        }
      }
    }
    return found;
  }();

  /// The glyph [codePoint] draws, or null when the font has none — tofu.
  int? glyphFor(int codePoint) => _cmap[codePoint];

  /// The glyph the font's own ligature for [name] (kebab-case) produces.
  int? glyphNamed(String name) => _ligatures[name];
}

/// `arrowUDownLeft` → `arrow-u-down-left`, Phosphor's own spelling.
String phosphorName(String camel) =>
    camel.replaceAllMapped(RegExp('[A-Z]'), (m) => '-${m[0]!.toLowerCase()}');
