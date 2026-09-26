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
  // The app, the design system it is drawn with and the phone: the tokens and
  // the chrome left for `karmashala_ui`, the companion left for its own
  // package, and a sweep that stopped at `lib/` would stop guarding exactly
  // the files that define the ramp and the touch surface that borrows it.
  final roots = [
    Directory('lib'),
    Directory('../packages/karmashala_ui/lib'),
    Directory('../packages/karmashala_companion/lib'),
  ];

  /// Where a size may be named. Everywhere else borrows a style.
  const themeLayer = {
    '../packages/karmashala_ui/lib/src/app_icons.dart',
    '../packages/karmashala_ui/lib/src/app_theme.dart',
    '../packages/karmashala_ui/lib/src/design_tokens.dart',
    '../packages/karmashala_ui/lib/src/ui_text_scale.dart',
  };

  /// Source of every `.dart` under [roots], with `//` comments removed — a
  /// rule quoted in prose is documentation, not debt.
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
        skip: (path) => path.endsWith('karmashala_ui/lib/src/app_icons.dart'),
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

  test('no raw fontSize outside the theme layer', () {
    // A hardcoded `fontSize:` is a widget deciding for itself how big text
    // is — the sites that ignored the theme were exactly the ones the "menus
    // don't follow text sizing" complaint was about. Sizes are named in the
    // theme layer (`TextTheme`, `MonoStyles`); feature widgets borrow a style.
    //
    // The debt set is a ratchet, not an amnesty: the files named here carried
    // a literal size before the rule existed, no new file may join, and one
    // that gets cleaned up must be struck off (the loop below enforces it).
    //
    // It is **empty**: `changes_view.dart` was the last entry and its one
    // `TextStyle(fontFamily: kMonoFamily, fontSize: 12)` is now
    // `MonoStyles.body`. Empty means the sweep below covers every file under
    // `lib/` outside the theme layer — not that it covers nothing, which the
    // liveness check underneath proves.
    const debt = <String>{};
    // A literal size only: `fontSize: someVariable` is a value that came from
    // somewhere accountable (a setting, a theme style) and is allowed.
    final pattern = RegExp(r'fontSize:\s*[0-9]');
    expect(
      hits(
        pattern,
        skip: (path) => themeLayer.contains(path) || debt.contains(path),
      ),
      isEmpty,
      reason: 'use a theme text style or MonoStyles instead of a literal size',
    );
    // The theme layer is where a size may be named, so it is also the proof
    // that the pattern is still finding sizes at all. Without this an empty
    // debt set and a broken matcher look identical from the outside.
    expect(
      hits(pattern).where((h) => themeLayer.contains(h.split(':').first)),
      isNotEmpty,
      reason:
          'the fontSize sweep found nothing anywhere — it has stopped '
          'guarding rather than been satisfied',
    );
    final remaining = hits(pattern).map((h) => h.split(':').first).toSet();
    for (final path in debt) {
      expect(
        remaining.contains(path),
        isTrue,
        reason:
            '$path no longer has a raw fontSize — strike it off the '
            'debt list so it cannot regress',
      );
    }
  });

  test('no icon size literal equal to the theme default', () {
    // `app_theme.dart` sets `iconButtonTheme.iconSize`, `iconTheme.size` and
    // every `*ButtonTheme` glyph to `Chrome.icon`, so a call site writing
    // `size: 16` is asking for what it already has. 31 `IconButton`s did, in
    // six different sizes, which is how the toolbars drifted apart in the
    // first place: the fix for a glyph that is the wrong size is a token, and
    // the fix for one that is the right size is nothing at all.
    //
    // The exclusion is the touch tree, not a debt list: the companion runs
    // under `UiDensity.touch`, whose theme puts every glyph at `Touch.icon`,
    // so 16 there is a real (if questionable) override rather than a no-op.
    final pattern = RegExp(
      r'(?<![A-Za-z])(?:size|iconSize):\s*16(?:\.0)?(?![0-9.])',
    );
    expect(
      hits(
        pattern,
        skip: (path) => path.startsWith('../packages/karmashala_companion/'),
      ),
      isEmpty,
      reason:
          'the theme already draws this glyph at Chrome.icon — drop the '
          'override rather than restating it',
    );
  });

  test('the guard can actually fail', () {
    // The assertion framework arriving self-tested, per the review's (D)12.
    final source = 'Icon(Icons.refresh), Colors.teal, x.shade700';
    expect(RegExp(r'(?<![A-Za-z])Icons\.').hasMatch(source), isTrue);
    expect(RegExp(r'(?<![A-Za-z])Colors\.teal').hasMatch(source), isTrue);
    expect(RegExp(r'\.shade\d+').hasMatch(source), isTrue);
    expect(
      RegExp(r'fontSize:\s*[0-9]').hasMatch('TextStyle(fontSize: 12)'),
      isTrue,
    );
    // And that the exclusions really exclude.
    expect(
      RegExp(r'(?<![A-Za-z])Icons\.').hasMatch('AppIcons.refresh'),
      isFalse,
    );
    expect(
      RegExp(r'(?<![A-Za-z])Colors\.').hasMatch('SemanticColors.of(context)'),
      isFalse,
    );
    expect(
      RegExp(r'fontSize:\s*[0-9]').hasMatch('fontSize: settings.textScale'),
      isFalse,
    );
    // The icon-default sweep has no in-repo positive to prove itself against —
    // the theme layer names `16.0` as a constant, not as a `size:` — so its
    // liveness is asserted here instead.
    final iconDefault = RegExp(
      r'(?<![A-Za-z])(?:size|iconSize):\s*16(?:\.0)?(?![0-9.])',
    );
    expect(iconDefault.hasMatch('Icon(AppIcons.x, size: 16)'), isTrue);
    expect(iconDefault.hasMatch('IconButton(iconSize: 16.0)'), isTrue);
    expect(
      iconDefault.hasMatch('Icon(AppIcons.x, size: Chrome.icon)'),
      isFalse,
    );
    expect(iconDefault.hasMatch('const SizedBox(width: 16)'), isFalse);
    expect(iconDefault.hasMatch('TextStyle(fontSize: 16)'), isFalse);
    expect(iconDefault.hasMatch('Icon(AppIcons.x, size: 160)'), isFalse);
  });
}
