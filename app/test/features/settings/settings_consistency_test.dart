import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The settings surfaces drawn from one kit, asserted rather than audited —
/// the same approach as `test/app/theme/ui_token_debt_test.dart`. Each rule
/// names the shared widget to use instead, and reads the source because the
/// debt is textual: a hand-built copy renders exactly like the real one until
/// the two drift.
void main() {
  const roots = [
    'lib/src/features/settings/presentation',
    'lib/src/features/environments/presentation',
    'lib/src/features/cli_detection/presentation',
    'lib/src/features/projects/presentation',
    'lib/src/features/ssh/presentation',
    'lib/src/features/remote/presentation',
  ];

  /// `file:line` for every line of the settings surfaces matching [pattern],
  /// with `//` comments removed.
  List<String> hits(RegExp pattern, {Set<String> except = const {}}) {
    final found = <String>[];
    for (final root in roots) {
      final dir = Directory(root);
      expect(dir.existsSync(), isTrue, reason: 'run from the app root');
      for (final file in dir.listSync(recursive: true).whereType<File>()) {
        final path = file.path.replaceAll(r'\', '/');
        if (!path.endsWith('.dart') || except.contains(path)) continue;
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final comment = lines[i].indexOf('//');
          final code = comment == -1
              ? lines[i]
              : lines[i].substring(0, comment);
          if (pattern.hasMatch(code)) found.add('$path:${i + 1}');
        }
      }
    }
    return found;
  }

  final card = RegExp(r'(?<![A-Za-z])Card\(');

  test('a settings card is a SettingsCard', () {
    expect(
      hits(
        card,
        except: {
          'lib/src/features/settings/presentation/settings_section.dart',
        },
      ),
      isEmpty,
      reason: 'use SettingsCard rather than a Card with its own margin',
    );
  });

  final spinner = RegExp(r'CircularProgressIndicator\(');

  test('a spinner is an InlineSpinner', () {
    expect(
      hits(spinner),
      isEmpty,
      reason:
          'use InlineSpinner at the size of the slot it stands in, not a '
          'hand-sized CircularProgressIndicator',
    );
  });

  // Sizes a token names. A 1 or 2px optical nudge stays a number; 4 and up
  // is a step on the spacing scale.
  final literalSize = RegExp(
    r'SizedBox\((height|width): [0-9]|EdgeInsets\.\w+\([^)]*(?<![.\w])([4-9]|[1-9][0-9]+)(?![.\w])'
    r'|TextStyle\(|maxWidth: [0-9]|maxWidth < [0-9]|width: [0-9]{3}',
  );

  test('the swept files use tokens, not size literals', () {
    // Files cleared of literals, which may not take them back. Named sizes
    // live as `static const` on their widget.
    const swept = {
      'lib/src/features/projects/presentation/new_project_dialog.dart',
      'lib/src/features/projects/presentation/new_project_dialog/source_section.dart',
      'lib/src/features/cli_detection/presentation/detected_projects_view.dart',
      'lib/src/features/settings/presentation/settings_row.dart',
      'lib/src/features/settings/presentation/settings_screen.dart',
      'lib/src/features/settings/presentation/choose_application_dialog.dart',
    };
    expect(
      hits(literalSize).where((hit) => swept.contains(hit.split(':').first)),
      isEmpty,
      reason: 'use Insets, DialogWidth, a text theme style or a named const',
    );
  });

  test('the guards can fail', () {
    expect(card.hasMatch('return Card('), isTrue);
    expect(card.hasMatch('SettingsCard('), isFalse);
    expect(spinner.hasMatch('child: CircularProgressIndicator()'), isTrue);
    expect(literalSize.hasMatch('const SizedBox(height: 12)'), isTrue);
    expect(literalSize.hasMatch('EdgeInsets.fromLTRB(16, 12, 12, 8)'), isTrue);
    expect(literalSize.hasMatch('EdgeInsets.only(top: 2)'), isFalse);
    expect(literalSize.hasMatch('EdgeInsets.all(Insets.xl)'), isFalse);
    expect(literalSize.hasMatch('if (constraints.maxWidth < 440) {'), isTrue);
    expect(literalSize.hasMatch('width: 208,'), isTrue);
  });
}
