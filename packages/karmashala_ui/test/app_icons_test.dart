import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/icons.dart';

/// Glyphs added by hand to the generated table: each has to name the codepoint
/// `PiconsRegular` 3.0.1 gives it, in the same font, or it draws as tofu.
void main() {
  const expected = {
    'house': (AppIcons.house, 0xe2c2),
    'record': (AppIcons.record, 0xe3ee),
    'fileVideo': (AppIcons.fileVideo, 0xea22),
    'dotsThree': (AppIcons.dotsThree, 0xe1fe),
  };

  expected.forEach((name, entry) {
    final (IconData glyph, int codePoint) = entry;
    test('$name is Phosphor Regular U+${codePoint.toRadixString(16)}', () {
      expect(glyph.codePoint, codePoint);
      expect(glyph.fontFamily, 'PhosphorRegular');
      expect(glyph.fontPackage, 'picons');
    });
  });

  test('record is its own glyph, not the plain circle', () {
    expect(AppIcons.record, isNot(AppIcons.circle));
  });

  test('dotsThree is the horizontal glyph, not the vertical one', () {
    expect(AppIcons.dotsThree, isNot(AppIcons.dotsThreeVertical));
  });
}
