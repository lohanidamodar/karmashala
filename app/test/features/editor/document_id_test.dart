import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/domain/document_id.dart';

/// **A document is named by where it is**: its environment and its path in
/// that environment's spelling — the server reads it there (slice 3c).
void main() {
  test("the server's own machine's files keep their bare path as their id",
      () {
    const path = EnvironmentPath(
      environmentId: localHostEnvironmentId,
      path: r'C:\src\app\lib\main.dart',
    );
    expect(documentIdOf(path), r'C:\src\app\lib\main.dart');
    expect(documentPathOf(r'C:\src\app\lib\main.dart'), path);
  });

  test('any other environment is part of the id, and comes back out', () {
    for (final other in const [
      EnvironmentPath(environmentId: 'ssh:box', path: '/home/me/main.dart'),
      EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/home/me/main.dart'),
    ]) {
      final id = documentIdOf(other);
      expect(id, '${other.environmentId}\u241F${other.path}');
      expect(documentPathOf(id), other);
    }
  });

  test('names are read in the spelling of their environment', () {
    expect(documentNameOf(r'C:\src\main.dart'), 'main.dart');
    expect(documentNameOf('/Users/me/main.dart'), 'main.dart');
    expect(documentNameOf('ssh:box\u241F/home/me/a\\b.txt'), r'a\b.txt');
  });
}
