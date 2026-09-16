import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';

import 'support/phosphor_font.dart';

/// Glyphs added by hand to the generated table: each has to name the codepoint
/// picons 3.0.1 gives it, in the same font, or it draws as tofu.
///
/// Every codepoint here was read from picons' own table
/// (`lib/src/picons_regular.dart` / `picons_fill.dart`) and checked against the
/// shipped font: the TTF's `cmap` maps it to the same glyph that the font's
/// own GSUB ligature for the Phosphor name (e.g. `record-fill`) produces.
void main() {
  const regular = 'PhosphorRegular';
  const fill = 'PhosphorFill';
  const expected = {
    'house': (AppIcons.house, 0xe2c2, regular),
    'record': (AppIcons.record, 0xe3ee, regular),
    'fileVideo': (AppIcons.fileVideo, 0xea22, regular),
    'recordFill': (AppIcons.recordFill, 0xe3ee, fill),
    'stopFill': (AppIcons.stopFill, 0xe46c, fill),
    'camera': (AppIcons.camera, 0xe10e, regular),
    'eye': (AppIcons.eye, 0xe220, regular),
    'eyeSlash': (AppIcons.eyeSlash, 0xe224, regular),
    'pause': (AppIcons.pause, 0xe39e, regular),
    'rocketLaunch': (AppIcons.rocketLaunch, 0xe3fe, regular),
    'prohibit': (AppIcons.prohibit, 0xe3de, regular),
    'arrowUDownLeft': (AppIcons.arrowUDownLeft, 0xe07e, regular),
    'squaresFour': (AppIcons.squaresFour, 0xe464, regular),
    'lockSimple': (AppIcons.lockSimple, 0xe308, regular),
    'keyboard': (AppIcons.keyboard, 0xe2d8, regular),
    'uploadSimple': (AppIcons.uploadSimple, 0xe4c0, regular),
    'broom': (AppIcons.broom, 0xec54, regular),
    'package': (AppIcons.package, 0xe390, regular),
    'numpad': (AppIcons.numpad, 0xe3c8, regular),
    'file': (AppIcons.file, 0xe230, regular),
    'arrowClockwise': (AppIcons.arrowClockwise, 0xe036, regular),
    'dotsThree': (AppIcons.dotsThree, 0xe1fe, regular),
  };

  expected.forEach((name, entry) {
    final (IconData glyph, int codePoint, String family) = entry;
    test('$name is $family U+${codePoint.toRadixString(16)}', () {
      expect(glyph.codePoint, codePoint);
      expect(glyph.fontFamily, family);
      expect(glyph.fontPackage, 'picons');
    });

    test("$name draws the font's own ${phosphorName(name)} glyph", () {
      final font = PhosphorFont.load(family);
      final drawn = font.glyphFor(codePoint);
      expect(drawn, isNotNull, reason: 'no glyph at that codepoint: tofu');
      expect(drawn, font.glyphNamed(phosphorName(name)));
    });
  });

  test('the font check can fail', () {
    final font = PhosphorFont.load('PhosphorRegular');
    // Record's codepoint is not the circle's glyph, and a made-up name is none.
    expect(
      font.glyphFor(AppIcons.record.codePoint),
      isNot(font.glyphNamed('circle')),
    );
    expect(font.glyphNamed('no-such-icon'), isNull);
    expect(font.glyphFor(0xe000 - 1), isNull);
  });

  test('record is its own glyph, not the plain circle', () {
    expect(AppIcons.record, isNot(AppIcons.circle));
  });

  test('dotsThree is the horizontal glyph, not the vertical one', () {
    expect(AppIcons.dotsThree, isNot(AppIcons.dotsThreeVertical));
  });

  test('a filled glyph is its outline twin in the fill family', () {
    // Phosphor keeps one codepoint per icon across weights.
    expect(AppIcons.recordFill.codePoint, AppIcons.record.codePoint);
    expect(AppIcons.recordFill, isNot(AppIcons.record));
    expect(AppIcons.stopFill.codePoint, AppIcons.stop.codePoint);
    expect(AppIcons.stopFill, isNot(AppIcons.stop));
  });

  test('the restart, refresh and undo arrows are three glyphs', () {
    expect({
      AppIcons.arrowClockwise,
      AppIcons.arrowsClockwise,
      AppIcons.arrowCounterClockwise,
    }, hasLength(3));
  });
}
