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

  test('the guards can fail', () {
    expect(card.hasMatch('return Card('), isTrue);
    expect(card.hasMatch('SettingsCard('), isFalse);
  });
}
