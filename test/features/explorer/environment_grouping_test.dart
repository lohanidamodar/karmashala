import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/environment_grouping.dart';

import '../../support/fixtures.dart';

/// **Where work runs, as a way of reading the Explorer.**
///
/// The tree has always been Project → Repository → sessions, which answers
/// "what am I working on" and never "what is running on that droplet". The
/// second spine groups the same projects by the machine they run on.
void main() {
  ExecutionEnvironment env(String id, EnvironmentKind kind, String name) =>
      ExecutionEnvironment(id: id, kind: kind, name: name, createdAt: testTime);

  final windows = env('windows', EnvironmentKind.windowsNative, 'Windows');
  final wsl = env('wsl:arch', EnvironmentKind.wsl, 'archlinux');
  final box = env('ssh:box', EnvironmentKind.ssh, 'do-box');
  final other = env('ssh:other', EnvironmentKind.ssh, 'alpha');

  test('nothing to group is no groups, not one empty one', () {
    expect(groupProjectsByEnvironment(const [], [windows]), isEmpty);
  });

  test('projects gather under the environment they run in', () {
    final groups = groupProjectsByEnvironment(
      [
        project(id: 'p1', name: 'app'),
        project(id: 'p2', name: 'docs'),
        project(id: 'p3', name: 'remote', environmentId: 'ssh:box'),
      ],
      [windows, box],
    );

    expect(groups.map((g) => g.label), ['Windows', 'do-box']);
    expect(groups.first.projects.map((p) => p.name), ['app', 'docs']);
    expect(groups.last.projects.single.name, 'remote');
  });

  test('this machine first, then WSL, then the ones over SSH', () {
    final groups = groupProjectsByEnvironment(
      [
        project(id: 'p1', environmentId: 'ssh:box'),
        project(id: 'p2', environmentId: 'wsl:arch'),
        project(id: 'p3', environmentId: 'windows'),
      ],
      [box, wsl, windows],
    );

    expect(groups.map((g) => g.label), ['Windows', 'archlinux', 'do-box']);
  });

  test('two machines of one kind read alphabetically', () {
    final groups = groupProjectsByEnvironment(
      [
        project(id: 'p1', environmentId: 'ssh:box'),
        project(id: 'p2', environmentId: 'ssh:other'),
      ],
      [box, other],
    );

    expect(groups.map((g) => g.label), ['alpha', 'do-box']);
  });

  test('an environment the workspace lost keeps its project, and its id', () {
    final groups = groupProjectsByEnvironment(
      [project(id: 'p1', environmentId: 'ssh:deleted')],
      [windows],
    );

    // Never folded into the local machine: a project that ran on somebody
    // else's box did not move here because the record went.
    expect(groups.single.label, 'ssh:deleted');
    expect(groups.single.environment, isNull);
    expect(groups.single.projects.single.id, 'p1');
  });

  test('a lost environment sorts last, under the ones we still hold', () {
    final groups = groupProjectsByEnvironment(
      [
        project(id: 'p1', environmentId: 'ssh:deleted'),
        project(id: 'p2', environmentId: 'windows'),
      ],
      [windows],
    );

    expect(groups.map((g) => g.label), ['Windows', 'ssh:deleted']);
  });
}
