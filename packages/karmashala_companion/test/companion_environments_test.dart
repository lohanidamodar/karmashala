import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/providers.dart';
import 'package:karmashala_companion/testing.dart';
import 'package:karmashala_remote/remote.dart';

/// **Which machine, behind one desktop.**
///
/// The phone holds sessions, not environments, so the machines are derived —
/// and the two ways that goes wrong are both about identity: grouping on a
/// label folds two machines that share a name, and inventing an id for a
/// desktop that sent none makes a key that means nothing anywhere else.
void main() {
  test('machines come back local first, then WSL, then SSH', () {
    final found = companionEnvironments([
      summary('a', environmentId: 'ssh:h1', environmentBadge: 'do-box',
          environmentKind: 'ssh', projectId: 'p1'),
      summary('b', environmentId: 'wsl:arch', environmentBadge: 'archlinux',
          environmentKind: 'wsl', projectId: 'p2'),
      summary('c', environmentId: 'windows', environmentBadge: 'Windows',
          environmentKind: 'windowsNative', projectId: 'p3'),
    ]);

    expect([for (final e in found) e.label], ['Windows', 'archlinux', 'do-box']);
  });

  test('a machine counts its projects once and its sessions each', () {
    final found = companionEnvironments([
      summary('a', environmentId: 'windows', environmentKind: 'windowsNative',
          environmentBadge: 'Windows', projectId: 'p1'),
      summary('b', environmentId: 'windows', environmentKind: 'windowsNative',
          environmentBadge: 'Windows', projectId: 'p1'),
      summary('c', environmentId: 'windows', environmentKind: 'windowsNative',
          environmentBadge: 'Windows', projectId: 'p2'),
    ]);

    expect(found.single.projects, 2);
    expect(found.single.sessions, 3);
  });

  test('the local host is named, never keyed', () {
    // What the desktop really sends for the machine it runs on: NO badge — a
    // badge is what tells a session card apart from the host you are sitting
    // at, and `environmentBadge` is null for the local host by design — but a
    // name. Every other fixture in this file sets a badge, which is why none of
    // them caught this.
    //
    // Without the name the label fell back to the id, and the local host's id
    // is the literal `windows` on every platform. A Mac listed itself as
    // "windows", next to a row reading "do-box".
    final found = companionEnvironments([
      summary('a', environmentId: 'windows', environmentName: 'macOS',
          environmentKind: 'localPosix', projectId: 'p1'),
      summary('b', environmentId: 'ssh:h1', environmentBadge: 'do-box',
          environmentKind: 'ssh', projectId: 'p2'),
    ]);

    expect([for (final e in found) e.label], ['macOS', 'do-box']);
    expect(
      found.first.label,
      isNot('windows'),
      reason: 'the database key is not a machine name',
    );
  });

  test('a machine known only from sessions is still named', () {
    // The timing case: sessions arrive before the workspace snapshot, so the
    // project branch — which has always had a name to fall back on — has
    // nothing to tally yet and the session branch names every machine.
    final found = companionEnvironments(
      [
        summary('a', environmentId: 'windows', environmentName: 'macOS',
            environmentKind: 'localPosix', projectId: 'p1'),
      ],
      projects: const [],
    );

    expect(found.single.label, 'macOS');
  });

  test('two machines sharing a name stay two machines', () {
    final found = companionEnvironments([
      summary('a', environmentId: 'ssh:one', environmentBadge: 'build-box',
          environmentKind: 'ssh', projectId: 'p1'),
      summary('b', environmentId: 'ssh:two', environmentBadge: 'build-box',
          environmentKind: 'ssh', projectId: 'p2'),
    ]);

    expect(
      found.length,
      2,
      reason: 'the id is what identifies a machine; the badge is what it is '
          'called, and two of them can be called the same thing',
    );
  });

  test('an older desktop sends no id, and the badge groups instead', () {
    final found = companionEnvironments([
      summary('a', environmentBadge: 'WSL · Ubuntu', projectId: 'p1'),
      summary('b', environmentBadge: 'WSL · Ubuntu', projectId: 'p2'),
    ]);

    expect(found.single.label, 'WSL · Ubuntu');
    expect(found.single.projects, 2);
    expect(
      found.single.kind,
      isNull,
      reason: 'a glyph guessed from a badge string would be a claim the '
          'desktop never made',
    );
    expect(
      found.single.key,
      'WSL · Ubuntu',
      reason: 'and the key is the badge itself rather than an invented id, '
          'which would mean nothing on any other desktop',
    );
  });

  test('a session the desktop said nothing about belongs to no machine', () {
    final found = companionEnvironments([
      summary('a', projectId: 'p1'),
      summary('b', environmentId: 'windows', environmentBadge: 'Windows',
          environmentKind: 'windowsNative', projectId: 'p2'),
    ]);

    expect([for (final e in found) e.label], ['Windows']);
    expect(
      found.single.sessions,
      1,
      reason: 'counting the unplaced one here would be a guess about where '
          'it runs',
    );
  });

  test('nothing said at all is no machines, not one empty one', () {
    expect(companionEnvironments([summary('a')]), isEmpty);
    expect(companionEnvironments(const []), isEmpty);
  });

  test('a machine nobody has started a session on is still a machine', () {
    final found = companionEnvironments(
      const [],
      projects: [
        RemoteWorkspaceProject(
          projectId: 'p1',
          name: 'Test ssh',
          environmentId: 'ssh:h1',
          environmentBadge: 'do-box',
          environmentKind: 'ssh',
        ),
      ],
    );

    expect(found.single.label, 'do-box');
    expect(found.single.projects, 1);
    expect(
      found.single.sessions,
      0,
      reason: 'nothing is running there, which is different from it not '
          'being somewhere you can go',
    );
  });

  test('a project with no sessions still counts toward its machine', () {
    final found = companionEnvironments(
      [
        summary('a', environmentId: 'windows', environmentBadge: 'Windows',
            environmentKind: 'windowsNative', projectId: 'p1'),
      ],
      projects: [
        const RemoteWorkspaceProject(
          projectId: 'p1',
          name: 'popupbits',
          environmentId: 'windows',
          environmentBadge: 'Windows',
          environmentKind: 'windowsNative',
        ),
        const RemoteWorkspaceProject(
          projectId: 'p2',
          name: 'quiet',
          environmentId: 'windows',
          environmentBadge: 'Windows',
          environmentKind: 'windowsNative',
        ),
      ],
    );

    expect(found.single.projects, 2);
    expect(found.single.sessions, 1);
  });

  test('the sessions of one machine come back by the same key', () {
    final sessions = [
      summary('a', environmentId: 'windows', projectId: 'p1'),
      summary('b', environmentId: 'wsl:arch', projectId: 'p2'),
      summary('c', environmentId: 'windows', projectId: 'p3'),
    ];

    expect(
      [for (final s in sessionsOnEnvironment(sessions, 'windows')) s.id],
      ['a', 'c'],
    );
  });
}
