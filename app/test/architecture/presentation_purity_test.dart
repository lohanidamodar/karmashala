import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'presentation_purity_allowlist.dart';

/// **The UI is pure** (UI overhaul spec §8): a widget draws state and sends
/// intents. It does not import a data layer, `dart:io`, a process runner or
/// the database; it asks an application-layer provider or service.
void main() {
  final forbidden = RegExp(
    r"^import '("
    r"[^']*/data/[^']*"
    r"|dart:io"
    r"|package:agent_cli/process\.dart"
    r"|[^']*/core/process/[^']*"
    r"|[^']*/core/database/[^']*"
    r"|package:drift[^']*"
    r")'",
    multiLine: true,
  );

  bool isUi(String path) =>
      path.contains('/presentation/') || path.startsWith('lib/src/app/shell/');

  final uiFiles = [
    for (final entity in Directory('lib/src').listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart'))
        p.posix.joinAll(p.split(entity.path)),
  ].where(isUi).toList()..sort();

  final offenders = {
    for (final path in uiFiles)
      if (forbidden.hasMatch(File(path).readAsStringSync())) path,
  };

  test('no new UI file reaches data, processes, files or the database', () {
    final fresh = offenders.difference(presentationPurityDebt).toList()..sort();
    expect(
      fresh,
      isEmpty,
      reason:
          'These UI files import a data layer, dart:io, a process runner or '
          'the database. Move that work behind an application-layer provider '
          'or service and have the widget ask it.',
    );
  });

  test('a cleaned file leaves the debt list', () {
    final cleaned = presentationPurityDebt.difference(offenders).toList()
      ..sort();
    expect(
      cleaned,
      isEmpty,
      reason:
          'These files no longer reach data, processes, files or the '
          'database: take them off presentation_purity_allowlist.dart.',
    );
  });
}
