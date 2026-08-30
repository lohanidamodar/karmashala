import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The colour and icon systems, asserted rather than audited.
///
/// Every loop that swept these found the same four shapes creeping back —
/// `Colors.<hue>`, `.shadeNNN`, `withOpacity`, a Material `Icons.` — because
/// nothing in the suite looked at them and a reviewer had to. This does the
/// looking. It reads the source rather than a rendered frame on purpose: the
/// debt is *textual*, and a widget test would have to render every screen to
/// find one badge.
void main() {
  final lib = Directory('lib');

  /// Source of every `.dart` under `lib/`, with `//` comments removed — a rule
  /// quoted in prose is documentation, not debt.
  Map<String, String> sources() {
    expect(
      lib.existsSync(),
      isTrue,
      reason: 'run from the package root: lib/ was not found',
    );
    return {
      for (final file in lib.listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart'))
          file.path.replaceAll(r'\', '/'): file
              .readAsStringSync()
              .split('\n')
              .map((line) {
                final comment = line.indexOf('//');
                return comment == -1 ? line : line.substring(0, comment);
              })
              .join('\n'),
    };
  }

  /// `file:line` for every match of [pattern], so a failure names the site
  /// instead of only the count.
  List<String> hits(RegExp pattern, {bool Function(String path)? skip}) {
    final found = <String>[];
    sources().forEach((path, source) {
      if (skip != null && skip(path)) return;
      final lines = source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (pattern.hasMatch(lines[i])) found.add('$path:${i + 1}');
      }
    });
    return found;
  }

  test('no Material icons outside the Phosphor set', () {
    // They also drag the whole Material icon font into the build alongside
    // Phosphor. `AppIcons` is the one place a glyph is named.
    expect(
      hits(
        RegExp(r'(?<![A-Za-z])Icons\.'),
        skip: (path) => path.endsWith('app/theme/app_icons.dart'),
      ),
      isEmpty,
      reason: 'add the glyph to AppIcons and use it',
    );
  });

  test('no raw Material palette colours', () {
    // `transparent`, `white` and `black` are structural — a scrim, a shadow, an
    // explicitly unpainted surface — and are not a palette choice. Every hue
    // is: it is a second accent in an app that has one.
    const structural = {'transparent', 'white', 'black'};
    final palette = <String>[];
    sources().forEach((path, source) {
      final lines = source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        for (final m in RegExp(
          r'(?<![A-Za-z])Colors\.([A-Za-z0-9]+)',
        ).allMatches(lines[i])) {
          if (!structural.contains(m.group(1))) {
            palette.add('$path:${i + 1} — ${m.group(0)}');
          }
        }
      }
    });
    expect(palette, isEmpty, reason: 'use SemanticColors or the ColorScheme');
  });

  test('no .shadeNNN, no Color.fromARGB, no withOpacity', () {
    // `.shadeNNN` is brightness-blind: it picks one ramp and stays on it when
    // the theme flips. `withOpacity` is the deprecated lossy form of
    // `withValues(alpha:)`.
    expect(hits(RegExp(r'\.shade\d+')), isEmpty);
    expect(hits(RegExp(r'Color\.fromARGB\(')), isEmpty);
    expect(hits(RegExp(r'\.withOpacity\(')), isEmpty);
  });

  test('the guard can actually fail', () {
    // The assertion framework arriving self-tested, per the review's (D)12.
    final source = 'Icon(Icons.refresh), Colors.teal, x.shade700';
    expect(RegExp(r'(?<![A-Za-z])Icons\.').hasMatch(source), isTrue);
    expect(RegExp(r'(?<![A-Za-z])Colors\.teal').hasMatch(source), isTrue);
    expect(RegExp(r'\.shade\d+').hasMatch(source), isTrue);
    // And that the exclusions really exclude.
    expect(
      RegExp(r'(?<![A-Za-z])Icons\.').hasMatch('AppIcons.refresh'),
      isFalse,
    );
    expect(
      RegExp(r'(?<![A-Za-z])Colors\.').hasMatch('SemanticColors.of(context)'),
      isFalse,
    );
  });
}
