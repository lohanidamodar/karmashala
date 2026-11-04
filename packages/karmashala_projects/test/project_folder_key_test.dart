import 'package:agent_cli/process.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:test/test.dart';

/// One folder is one project: [projectFolderKey] is what says two roots are
/// the same folder, however each was spelled.
void main() {
  String key(String environmentId, String path, EnvironmentKind? kind) =>
      projectFolderKey(
        EnvironmentPath(environmentId: environmentId, path: path),
        kind,
      );

  const windows = EnvironmentKind.windowsNative;
  const wsl = EnvironmentKind.wsl;
  const ssh = EnvironmentKind.ssh;

  test('a Windows folder is one key whatever its case and slashes', () {
    final plain = key('windows', r'C:\Users\me\projects\games\momo', windows);
    expect(key('windows', r'c:\users\ME\projects\games\momo\', windows), plain);
    expect(key('windows', 'C:/Users/me/projects/games/momo', windows), plain);
  });

  test("WSL's /mnt/c path is the Windows folder it names", () {
    expect(
      key('wsl:arch', '/mnt/c/Users/me/projects/pasa', wsl),
      key('windows', r'C:\Users\me\projects\pasa', windows),
    );
    expect(key('wsl:arch', '/mnt/c', wsl), key('windows', r'C:\', windows));
  });

  test("a WSL home folder is the distribution's own, and keeps its case", () {
    expect(
      key('wsl:arch', '/home/me/App', wsl),
      isNot(key('wsl:arch', '/home/me/app', wsl)),
    );
    expect(
      key('wsl:arch', '/home/me/app', wsl),
      isNot(key('wsl:other', '/home/me/app', wsl)),
    );
  });

  test("an SSH host's folder is never this machine's", () {
    expect(
      key('ssh:box', '/mnt/c/Users/me/app', ssh),
      isNot(key('windows', r'C:\Users\me\app', windows)),
    );
  });

  group('duplicateProjects', () {
    Project project(
      String id,
      String environmentId,
      String path,
      int minute, {
      String? kind,
    }) => Project(
      id: id,
      name: id,
      root: EnvironmentPath(environmentId: environmentId, path: path),
      createdAt: DateTime.utc(2026, 11, 4, 0, minute),
      kind: kind,
    );

    EnvironmentKind? kindOf(String id) => id == 'windows' ? windows : wsl;

    test('the newer project at a folder is the duplicate of the older', () {
      final found = duplicateProjects([
        project('second', 'windows', r'C:\games\momo-pasal', 50),
        project('first', 'windows', r'C:\games\momo-pasal', 12),
        project('other', 'windows', r'C:\games\tiny-temple', 12),
      ], kindOf);
      expect(found, hasLength(1));
      expect(found.single.keep.id, 'first');
      expect([for (final d in found.single.duplicates) d.id], ['second']);
    });

    test('across WSL and Windows, and never among the server\'s own', () {
      final found = duplicateProjects([
        project('win', 'windows', r'C:\work\pasa', 1),
        project('wsl', 'wsl:arch', '/mnt/c/work/pasa', 2),
        project('s1', 'windows', r'C:\k\scratch', 3, kind: 'scratch'),
        project('s2', 'windows', r'C:\k\scratch', 4, kind: 'scratch'),
      ], kindOf);
      expect(found.single.keep.id, 'win');
      expect(found.single.duplicates.single.id, 'wsl');
    });
  });
}
