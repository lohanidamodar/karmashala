import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/src/application/companion_environments.dart';
import 'package:karmashala_remote/remote.dart';

/// One machine must be one row, and choosing it must narrow what is behind it.
///
/// Both halves were broken together on 2026-09-16: the desktop's `projects.list`
/// handler re-listed the fields it copied and so dropped `environmentId` and
/// `environmentKind`, which left projects keyed by badge and sessions keyed by
/// id — one machine drawn twice, the duplicate wearing the neutral glyph — and
/// the screen then merged every project behind whichever row was tapped.
void main() {
  RemoteWorkspaceProject project(
    String id, {
    String? environmentId,
    String? badge,
    String? kind,
  }) => RemoteWorkspaceProject(
    projectId: id,
    name: id,
    environmentId: environmentId,
    environmentBadge: badge,
    environmentKind: kind,
  );

  group('one machine is one row', () {
    test('a project and a session on it agree on the key', () {
      final machines = companionEnvironments(
        const [],
        projects: [
          project(
            'p1',
            environmentId: 'wsl:arch',
            badge: 'WSL · arch',
            kind: 'wsl',
          ),
        ],
      );
      expect(machines, hasLength(1));
      expect(machines.single.key, 'wsl:arch');
      expect(machines.single.kind, 'wsl');
    });

    test('a project that lost its id splits the machine in two', () {
      // The shape of the bug, kept so the fix cannot quietly come undone: the
      // desktop sends sessions with an id and projects without one.
      final machines = companionEnvironments(
        const [],
        projects: [project('p1', badge: 'WSL · arch')],
      );
      expect(machines.single.key, 'WSL · arch');
      expect(
        machines.single.key,
        isNot('wsl:arch'),
        reason: 'a badge key and an id key are two rows for one machine',
      );
      expect(machines.single.kind, isNull, reason: 'and it draws no glyph');
    });
  });

  group('projectsOnEnvironment', () {
    final onWsl = project(
      'p1',
      environmentId: 'wsl:arch',
      badge: 'WSL · arch',
      kind: 'wsl',
    );
    final onWindows = project(
      'p2',
      environmentId: 'windows',
      badge: 'Windows',
      kind: 'windowsNative',
    );

    test('keeps only the machine asked for', () {
      expect(
        projectsOnEnvironment([
          onWsl,
          onWindows,
        ], 'wsl:arch').map((p) => p.projectId),
        ['p1'],
      );
    });

    test('a machine with nothing on it answers empty, not everything', () {
      expect(projectsOnEnvironment([onWsl, onWindows], 'ssh:box'), isEmpty);
    });

    test('falls back to the badge, the way the grouping key does', () {
      final badgeOnly = project('p3', badge: 'WSL · arch');
      expect(
        projectsOnEnvironment([
          badgeOnly,
        ], 'WSL · arch').map((p) => p.projectId),
        ['p3'],
      );
    });

    test('the same rule as the session filter, so the two cannot disagree', () {
      const key = 'wsl:arch';
      expect(
        projectsOnEnvironment([onWsl, onWindows], key).length,
        1,
        reason: 'sessionsOnEnvironment keys on environmentId ?? badge too',
      );
    });
  });
}
