import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/data/local_document_source.dart';
import 'package:karmashala/src/features/editor/domain/document_id.dart';

/// **A document is named by where it is**: its environment and its path in
/// that environment's spelling. This machine's files keep the bare host path
/// every tab stored before, so nothing persisted needs migrating.
void main() {
  test("this machine's files keep their host path as their id", () {
    const path = EnvironmentPath(
      environmentId: localHostEnvironmentId,
      path: r'C:\src\app\lib\main.dart',
    );
    expect(documentIdOf(path), r'C:\src\app\lib\main.dart');
    expect(documentPathOf(r'C:\src\app\lib\main.dart'), path);
    expect(isLocalDocument(r'C:\src\app\lib\main.dart'), isTrue);
  });

  test('any other environment is part of the id, and comes back out', () {
    const ssh = EnvironmentPath(
      environmentId: 'ssh:box',
      path: '/home/me/app/main.dart',
    );
    final id = documentIdOf(ssh);
    expect(id, 'ssh:box\u241F/home/me/app/main.dart');
    expect(documentPathOf(id), ssh);
    expect(isLocalDocument(id), isFalse);
    expect(hostPathOfDocument(id), isNull, reason: 'SFTP only');
  });

  test('a WSL file is its POSIX path, read over the share', () {
    const wsl = EnvironmentPath(
      environmentId: 'wsl:Ubuntu',
      path: '/home/me/app/main.dart',
    );
    final id = documentIdOf(wsl);
    expect(documentPathOf(id), wsl);
    expect(
      hostPathOfDocument(id),
      r'\\wsl.localhost\Ubuntu\home\me\app\main.dart',
    );
  });

  test('a tab stored with a WSL share path is the same document as a fresh '
      'open of that file', () {
    const legacy = r'\\wsl.localhost\Ubuntu\home\me\app\main.dart';
    expect(
      documentPathOf(legacy),
      const EnvironmentPath(
        environmentId: 'wsl:Ubuntu',
        path: '/home/me/app/main.dart',
      ),
    );
    expect(
      canonicalDocumentId(legacy),
      documentIdOf(
        const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/home/me/app/main.dart',
        ),
      ),
    );
    expect(documentPathOf(r'\\wsl$\Ubuntu\etc\hosts').path, '/etc/hosts');
    expect(hostPathOfDocument(legacy), legacy);
  });

  test('names are read in the spelling of their environment', () {
    expect(documentNameOf(r'C:\src\main.dart'), 'main.dart');
    expect(documentNameOf('/Users/me/main.dart'), 'main.dart');
    expect(documentNameOf('ssh:box\u241F/home/me/a\\b.txt'), r'a\b.txt');
  });
}
