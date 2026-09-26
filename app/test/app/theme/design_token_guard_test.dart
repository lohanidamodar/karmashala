import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// State layers and motion, asserted rather than audited: the two token
/// families that had drifted into nine alphas and twenty literal durations.
void main() {
  final roots = [
    Directory('lib'),
    Directory('../packages/karmashala_ui/lib'),
    Directory('../packages/karmashala_companion/lib'),
    Directory('../packages/karmashala_devices/lib'),
  ];

  /// Where a state layer or a duration may be named.
  const tokenLayer = {'../packages/karmashala_ui/lib/src/design_tokens.dart'};

  /// Presentation code: what draws. A timeout or a poll elsewhere is not motion.
  bool isPresentation(String path) =>
      path.contains('/presentation/') ||
      path.startsWith('lib/src/app/') ||
      path.startsWith('../packages/karmashala_ui/lib/');

  Map<String, String> sources() {
    for (final root in roots) {
      expect(
        root.existsSync(),
        isTrue,
        reason: 'run from the app root: ${root.path} was not found',
      );
    }
    return {
      for (final root in roots)
        for (final file in root.listSync(recursive: true).whereType<File>())
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

  /// `file:line` for every match, whole-file so a call split across lines is
  /// still seen.
  List<String> hits(RegExp pattern, bool Function(String path) include) {
    final found = <String>[];
    sources().forEach((path, source) {
      if (tokenLayer.contains(path) || !include(path)) return;
      for (final match in pattern.allMatches(source)) {
        final line = '\n'.allMatches(source.substring(0, match.start)).length;
        found.add('$path:${line + 1}');
      }
    });
    return found;
  }

  final accentAlpha = RegExp(r'\.primary\s*\.withValues\(\s*alpha:');
  final millis = RegExp(r'Duration\(\s*milliseconds:');

  test('no raw accent alpha outside StateLayers', () {
    expect(
      hits(accentAlpha, (_) => true),
      isEmpty,
      reason: 'use StateLayers (selected, subtle, dropTarget, …) instead',
    );
  });

  test('no literal millisecond duration in presentation code', () {
    // Not motion, so not Motion's: a repaint interval, a filesystem probe's
    // patience and a watched file's settle. Tooltip wait is named in the theme
    // itself.
    const notMotion = {
      'lib/src/app/shell/keymap_controller.dart',
      'lib/src/app/shell/logs_panel.dart',
      '../packages/karmashala_ui/lib/src/file_browser.dart',
      '../packages/karmashala_ui/lib/src/app_theme.dart',
    };
    expect(
      hits(millis, (path) => isPresentation(path) && !notMotion.contains(path)),
      isEmpty,
      reason: 'animate with Motion.of(context), which honours reduced motion',
    );
  });

  test('every mono family carries the mono fallback', () {
    // A terminal grid and a rendered cast take a family name only; xterm and
    // the renderer bring their own fallback lists.
    const familyOnly = {
      'lib/src/features/terminal/presentation/terminal_pane_view.dart',
      'lib/src/features/terminal/application/terminal_recording_controller.dart',
    };
    final family = RegExp(r'fontFamily:\s*kMonoFamily');
    final fallback = RegExp(r'fontFamilyFallback:\s*kMonoFallback');
    final bare = <String>[];
    sources().forEach((path, source) {
      if (tokenLayer.contains(path) || familyOnly.contains(path)) return;
      final families = family.allMatches(source).length;
      if (families > fallback.allMatches(source).length) {
        bare.add(
          '$path: $families family, '
          '${fallback.allMatches(source).length} fallback',
        );
      }
    });
    expect(bare, isEmpty, reason: 'add fontFamilyFallback: kMonoFallback');
  });

  /// A generic family name where the mono token belongs: `'monospace'` is not
  /// a font on Windows or macOS, so the line falls back to whatever the engine
  /// picks — never the Consolas or Monaco the rest of the app draws code in.
  final bareMonospace = RegExp(r'''fontFamily:\s*['"]monospace['"]''');

  test('no bare monospace family in presentation code', () {
    expect(
      hits(bareMonospace, isPresentation),
      isEmpty,
      reason: 'use fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback',
    );
  });

  test('the guards can fail', () {
    expect(bareMonospace.hasMatch("fontFamily: 'monospace',"), isTrue);
    expect(bareMonospace.hasMatch('fontFamily: kMonoFamily,'), isFalse);
    expect(
      accentAlpha.hasMatch('scheme.primary.withValues(alpha: 0.12)'),
      isTrue,
    );
    expect(accentAlpha.hasMatch('StateLayers.selected(scheme)'), isFalse);
    expect(millis.hasMatch('const Duration(milliseconds: 150)'), isTrue);
    expect(millis.hasMatch('Motion.of(context).fast'), isFalse);
    // The token layer is where both are allowed, and it still has them.
    final tokens = sources()[tokenLayer.single]!;
    expect(accentAlpha.hasMatch(tokens), isTrue);
    expect(millis.hasMatch(tokens), isTrue);
  });
}
