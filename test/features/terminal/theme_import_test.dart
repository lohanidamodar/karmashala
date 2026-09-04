import 'dart:io';

import 'package:karmashala/src/features/terminal/data/ghostty_theme.dart';
import 'package:karmashala/src/features/terminal/data/warp_theme.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

String _fixture(String name) =>
    File('test/features/terminal/fixtures/$name').readAsStringSync();

void main() {
  group('normalizeHexColor', () {
    test('accepts 6-digit hex with or without a hash', () {
      expect(normalizeHexColor('#1A2B3C'), '#1a2b3c');
      expect(normalizeHexColor('1A2B3C'), '#1a2b3c');
    });

    test('expands 3-digit hex', () {
      // Both formats get the same treatment; the reference implementation
      // expands one and not the other, which is a wart worth not copying.
      expect(normalizeHexColor('#f00'), '#ff0000');
      expect(normalizeHexColor('abc'), '#aabbcc');
    });

    test('strips surrounding quotes', () {
      expect(normalizeHexColor('"#000000"'), '#000000');
      expect(normalizeHexColor("'#000000'"), '#000000');
    });

    test('rejects everything else', () {
      for (final bad in [
        null,
        '',
        '   ',
        'red',
        'rgb:aa/bb/cc',
        '#12345',
        '#1234567',
        '#12ZZ12',
        '#12345678',
      ]) {
        expect(normalizeHexColor(bad), isNull, reason: 'rejects "$bad"');
      }
    });
  });

  group('TerminalPalette', () {
    test('an empty palette is not usable', () {
      expect(const TerminalPalette().isUsable, isFalse);
    });

    test('usable needs a background, a foreground and one ANSI colour', () {
      expect(
        const TerminalPalette(
          background: '#000000',
          foreground: '#ffffff',
        ).isUsable,
        isFalse,
      );
      expect(
        const TerminalPalette(
          background: '#000000',
          foreground: '#ffffff',
          ansi: {0: '#111111'},
        ).isUsable,
        isTrue,
      );
    });

    test('applyTo overrides only what it carries', () {
      const base = TerminalThemes.defaultTheme;
      final applied = const TerminalPalette(
        background: '#010203',
        ansi: {1: '#ff0000'},
      ).applyTo(base);

      expect(applied.background, const Color(0xFF010203));
      expect(applied.red, const Color(0xFFFF0000));
      // Untouched keys keep the base theme's value.
      expect(applied.foreground, base.foreground);
      expect(applied.brightWhite, base.brightWhite);
      expect(applied.searchHitBackground, base.searchHitBackground);
    });
  });

  group('parseGhosttyConfig', () {
    test('reads a real theme file', () {
      final palette = ghosttyPalette(
        parseGhosttyConfig(_fixture('ghostty_tomorrow_night')),
      );

      expect(palette.background, '#000000');
      expect(palette.foreground, '#eaeaea');
      expect(palette.cursor, '#eaeaea');
      expect(palette.selectionBackground, '#424242');
      expect(palette.selectionForeground, '#eaeaea');
      expect(palette.ansi[0], '#000000');
      expect(palette.ansi[1], '#d54e53');
      expect(palette.ansi[15], '#ffffff');
      expect(palette.ansi, hasLength(16));
      expect(palette.isUsable, isTrue);
    });

    test('survives every awkward line a real config contains', () {
      final parsed = parseGhosttyConfig(_fixture('ghostty_config'));
      final palette = ghosttyPalette(parsed);

      // Inline comments are stripped, but only after whitespace.
      expect(palette.background, '#1a1a1a');
      // Whitespace around = is irrelevant.
      expect(palette.foreground, '#c5c8c6');
      // A quoted palette colour still parses.
      expect(palette.ansi[0], '#000000');
      // Bare 3-digit and bare 6-digit both work.
      expect(palette.ansi[1], '#ff0000');
      expect(palette.ansi[2], '#00ff00');
      // Out-of-range indices, unparseable entries and bad colours are dropped
      // rather than throwing.
      expect(palette.ansi.containsKey(99), isFalse);
      expect(palette.ansi, hasLength(3));
      expect(palette.cursor, isNull);
      // Non-colour keys are simply not our business.
      expect(parsed.containsKey('font-family'), isTrue);
    });

    test('never throws on garbage', () {
      for (final junk in ['', '\n\n\n', '#####', 'no equals here', '= = = =']) {
        expect(() => parseGhosttyConfig(junk), returnsNormally);
        expect(ghosttyPalette(parseGhosttyConfig(junk)).isUsable, isFalse);
      }
    });

    test('handles a CRLF file', () {
      // Built here rather than committed as a fixture: git normalises line
      // endings on checkout, so a CRLF fixture would silently become LF on a
      // fresh clone and the test would stop testing anything.
      const crlf =
          '# CRLF file\r\n'
          'background = #101010\r\n'
          'foreground = #f0f0f0\r\n'
          'palette = 0=#010101\r\n';
      final palette = ghosttyPalette(parseGhosttyConfig(crlf));
      expect(palette.background, '#101010');
      expect(palette.foreground, '#f0f0f0');
      expect(palette.ansi[0], '#010101');
    });

    test('a repeated scalar key takes the last value', () {
      final palette = ghosttyPalette(
        parseGhosttyConfig('background = #111111\nbackground = #222222'),
      );
      expect(palette.background, '#222222');
    });
  });

  group('parseWarpTheme', () {
    test('reads a real theme file', () {
      final result = parseWarpTheme(_fixture('warp_tokyo_night.yaml'));

      expect(result, isA<WarpThemeOk>());
      final ok = result as WarpThemeOk;
      expect(ok.name, 'Tokyo Night');
      expect(ok.palette.background, '#1a1b26');
      expect(ok.palette.foreground, '#c0caf5');
      expect(ok.palette.cursor, '#c0caf5');
      expect(ok.palette.ansi[0], '#15161e');
      expect(ok.palette.ansi[1], '#f7768e');
      expect(ok.palette.ansi[8], '#414868');
      expect(ok.palette.ansi[15], '#c0caf5');
      expect(ok.palette.ansi, hasLength(16));
      expect(ok.notes, isEmpty);
      expect(ok.palette.isUsable, isTrue);
    });

    test('takes the first endpoint of a gradient and says so', () {
      final result = parseWarpTheme(_fixture('warp_gradient.yaml'));

      expect(result, isA<WarpThemeOk>());
      final ok = result as WarpThemeOk;
      expect(ok.palette.background, '#002633');
      expect(ok.notes, isNotEmpty);
      expect(ok.notes.join(' '), contains('gradient'));
      // Flow-style mappings are ordinary YAML and must parse.
      expect(ok.palette.ansi[0], '#0a0a0a');
      expect(ok.palette.ansi[15], '#ffffff');
    });

    test('invalid YAML is an error, not an exception', () {
      final result = parseWarpTheme(_fixture('warp_malformed.yaml'));
      expect(result, isA<WarpThemeError>());
      expect((result as WarpThemeError).reason, isNotEmpty);
    });

    test(
      'a theme without enough colour is rejected with a readable reason',
      () {
        final result = parseWarpTheme(_fixture('warp_incomplete.yaml'));
        expect(result, isA<WarpThemeError>());
        expect((result as WarpThemeError).reason, contains('background'));
      },
    );

    test('a non-map document is rejected', () {
      for (final junk in ['- a\n- b', 'just a string', '42']) {
        expect(parseWarpTheme(junk), isA<WarpThemeError>());
      }
    });

    test('falls back to the file name when the theme has no name', () {
      final result = parseWarpTheme(
        "background: '#111111'\nforeground: '#eeeeee'\n"
        'terminal_colors:\n  normal:\n    black: "#000000"\n',
        fallbackName: 'my_theme',
      );
      expect((result as WarpThemeOk).name, 'my_theme');
    });

    test('non-string scalars are ignored rather than coerced', () {
      final result = parseWarpTheme(
        "background: '#111111'\nforeground: 42\n"
        'terminal_colors:\n  normal:\n    black: "#000000"\n',
      );
      // foreground was unusable, so the theme is below the usability bar.
      expect(result, isA<WarpThemeError>());
    });

    test('never throws, whatever it is handed', () {
      for (final junk in ['', '\u0000', '{{{{', 'a: *undefined_alias']) {
        expect(() => parseWarpTheme(junk), returnsNormally, reason: junk);
      }
    });
  });
}
