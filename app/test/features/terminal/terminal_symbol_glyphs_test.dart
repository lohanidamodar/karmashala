import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_pane_view.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_text_style.dart';
import 'package:yaml/yaml.dart';

/// The marks Claude Code and Codex draw in their footers and transcripts. The
/// phone drew `⏵⏵ auto mode on` as two boxes: Android has no glyph for it.
const _agentMarks = [
  0x23F5, // ⏵ mode arrows
  0x23F8, // ⏸ manual mode
  0x23BF, // ⎿ tool result
  0x273B, // ✻ spinner
  0x2736, // ✶
  0x273D, // ✽
  0x25CF, // ● message
  0x25EF, // ◯
  0x25D0, // ◐
  0x276F, // ❯ prompt
  0x23FA, // ⏺
];

final _boxAndBlocks = [for (var c = 0x2500; c <= 0x259F; c++) c];

const _uiPackage = '../packages/karmashala_ui';
const _packagePrefix = 'packages/karmashala_ui/';

/// Each bundled family the terminal names, to the regular file declaring it.
Map<String, String> _bundledFontFiles() {
  final pubspec =
      loadYaml(File('$_uiPackage/pubspec.yaml').readAsStringSync()) as YamlMap;
  final fonts = (pubspec['flutter'] as YamlMap)['fonts'] as YamlList;
  return {
    for (final font in fonts.cast<YamlMap>())
      '$_packagePrefix${font['family']}':
          '$_uiPackage/${((font['fonts'] as YamlList).first as YamlMap)['asset']}',
  };
}

/// The families of the terminal's chain this app ships, in order.
List<String> _bundledChain() {
  final style = terminalTextStyle(kPhoneTerminalFontSize);
  return [
    style.fontFamily,
    ...style.fontFamilyFallback,
  ].where((family) => family.startsWith(_packagePrefix)).toList();
}

void main() {
  test('every agent mark has a glyph in a font the terminal bundles', () {
    final files = _bundledFontFiles();
    final chain = _bundledChain();
    final covered = <int>{
      for (final family in chain)
        ..._cmapOf(File(files[family]!).readAsBytesSync()),
    };
    String name(int c) => 'U+${c.toRadixString(16).toUpperCase()}';
    expect(
      [
        for (final c in [..._agentMarks, ..._boxAndBlocks])
          if (!covered.contains(c)) '${name(c)} ${String.fromCharCode(c)}',
      ],
      isEmpty,
      reason: 'no font in $chain draws these',
    );
  });

  testWidgets('at phone size each mark draws a glyph, not the missing box', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final files = _bundledFontFiles();
    await tester.runAsync(() async {
      for (final family in _bundledChain()) {
        final bytes = File(files[family]!).readAsBytesSync();
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
    });

    final style = terminalTextStyle(
      kPhoneTerminalFontSize,
    ).toTextStyle(color: Colors.black);
    Future<Uint8List> draw(int codePoint) async =>
        (await tester.runAsync(() => _pixels(codePoint, style)))!;

    // A private-use code point no font here maps: what "missing" looks like.
    final missing = await draw(0xE000);
    expect(
      await draw(0xF8FF),
      missing,
      reason: 'the check can tell a missing glyph',
    );
    for (final c in [..._agentMarks, 0x2500, 0x2502, 0x256D, 0x2580, 0x2588]) {
      expect(
        await draw(c),
        isNot(missing),
        reason: 'U+${c.toRadixString(16).toUpperCase()} draws the missing box',
      );
    }
  });
}

Future<Uint8List> _pixels(int codePoint, TextStyle style) async {
  final painter = TextPainter(
    text: TextSpan(text: String.fromCharCode(codePoint), style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(const Color(0xFFFFFFFF), BlendMode.src);
  painter.paint(canvas, Offset.zero);
  painter.dispose();
  final image = await recorder.endRecording().toImage(32, 32);
  final data = await image.toByteData();
  image.dispose();
  return data!.buffer.asUint8List();
}

/// The code points a TrueType font maps to a real glyph, from its cmap
/// format 4 or 12 subtables.
Set<int> _cmapOf(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var cmap = -1;
  for (var i = 0; i < data.getUint16(4); i++) {
    final record = 12 + i * 16;
    if (String.fromCharCodes(bytes, record, record + 4) == 'cmap') {
      cmap = data.getUint32(record + 8);
    }
  }
  final mapped = <int>{};
  for (var i = 0; i < data.getUint16(cmap + 2); i++) {
    final table = cmap + data.getUint32(cmap + 8 + i * 8);
    switch (data.getUint16(table)) {
      case 4:
        final segments = data.getUint16(table + 6) ~/ 2;
        final ends = table + 14;
        final starts = ends + segments * 2 + 2;
        final deltas = starts + segments * 2;
        final ranges = deltas + segments * 2;
        for (var s = 0; s < segments; s++) {
          final start = data.getUint16(starts + s * 2);
          final end = data.getUint16(ends + s * 2);
          final delta = data.getInt16(deltas + s * 2);
          final range = data.getUint16(ranges + s * 2);
          for (var c = start; c <= end && c != 0xFFFF; c++) {
            var glyph = range == 0
                ? c + delta
                : data.getUint16(ranges + s * 2 + range + (c - start) * 2);
            if (range != 0 && glyph != 0) glyph += delta;
            if (glyph & 0xFFFF != 0) mapped.add(c);
          }
        }
      case 12:
        for (var g = 0; g < data.getUint32(table + 12); g++) {
          final group = table + 16 + g * 12;
          final start = data.getUint32(group);
          for (var c = start; c <= data.getUint32(group + 4); c++) {
            if (data.getUint32(group + 8) + c - start != 0) mapped.add(c);
          }
        }
    }
  }
  return mapped;
}
