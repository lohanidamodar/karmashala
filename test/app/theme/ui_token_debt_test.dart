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

  test('no raw fontSize outside the theme layer', () {
    // A hardcoded `fontSize:` is a widget deciding for itself how big text
    // is — the sites that ignored the theme were exactly the ones the "menus
    // don't follow text sizing" complaint was about. Sizes are named in the
    // theme layer (`TextTheme`, `MonoStyles`); feature widgets borrow a style.
    //
    // The debt set is a ratchet, not an amnesty: the files named here carried
    // a literal size before the rule existed, no new file may join, and one
    // that gets cleaned up must be struck off (the loop below enforces it).
    const debt = {
      'lib/src/features/detail/presentation/repository_info_view.dart',
      'lib/src/features/environments/presentation/environments_section.dart',
      'lib/src/features/fanout/presentation/comparison_view.dart',
      'lib/src/features/git/presentation/changes_view.dart',
      'lib/src/features/sessions/presentation/chat_transcript.dart',
      'lib/src/features/sessions/presentation/markdown_message.dart',
      'lib/src/features/sessions/presentation/message_composer.dart',
      'lib/src/features/ssh/presentation/host_key_changed_alert.dart',
      'lib/src/features/ssh/presentation/host_key_dialog.dart',
      'lib/src/features/ssh/presentation/known_hosts_section.dart',
      'lib/src/features/ssh/presentation/remote_file_browser_dialog.dart',
      'lib/src/features/ssh/presentation/ssh_hosts_section.dart',
    };
    // A literal size only: `fontSize: someVariable` is a value that came from
    // somewhere accountable (a setting, a theme style) and is allowed.
    final pattern = RegExp(r'fontSize:\s*[0-9]');
    expect(
      hits(
        pattern,
        skip: (path) =>
            path.startsWith('lib/src/app/theme/') || debt.contains(path),
      ),
      isEmpty,
      reason: 'use a theme text style or MonoStyles instead of a literal size',
    );
    final remaining = hits(pattern).map((h) => h.split(':').first).toSet();
    for (final path in debt) {
      expect(
        remaining.contains(path),
        isTrue,
        reason: '$path no longer has a raw fontSize — strike it off the '
            'debt list so it cannot regress',
      );
    }
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
