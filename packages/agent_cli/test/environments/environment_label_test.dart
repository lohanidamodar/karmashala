/// One vocabulary for naming an execution environment, shared by the desktop's
/// New project dropdown and by what the phone is told over the wire — so a
/// user who reads "WSL · Ubuntu" on one surface never meets a different
/// spelling of the same machine on the other.
library;

import 'package:agent_cli/src/environments/environment_label.dart';
import 'package:agent_cli/src/environments/local_environment.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  test('a WSL environment reads as its distribution', () {
    expect(
      environmentLabel(wslEnv(id: 'wsl:Ubuntu-24.04', distro: 'Ubuntu-24.04')),
      'WSL · Ubuntu-24.04',
    );
  });

  test('a Windows environment reads as Windows', () {
    expect(environmentLabel(windowsEnv()), 'Windows');
  });

  test('an SSH environment reads as its host', () {
    expect(environmentLabel(sshEnvFixture()), 'SSH · build-box');
  });

  group('nothing worth showing', () {
    test('a WSL row with no distribution and no name is unnamed', () {
      expect(environmentLabel(wslEnv(distro: '')), isNull);
    });

    test('an SSH row saved with a blank name is unnamed', () {
      expect(environmentLabel(sshEnvFixture(name: '   ')), isNull);
    });

    test('a WSL row falls back to its own name when the distro is missing', () {
      final env = wslEnv().copyWith(wslDistribution: '');
      expect(
        environmentLabel(env),
        'WSL · Ubuntu',
        reason: 'the row still carries a name; only an empty one is useless',
      );
    });
  });

  group('describeEnvironmentId', () {
    test('names the local host rather than printing its database key', () {
      // The key is the literal `windows` on every platform. Printing it raw is
      // how a Mac's New session dialog offered `codex · windows`, and how the
      // hook installer warned it could not install hooks "in windows".
      expect(
        describeEnvironmentId(localHostEnvironmentId),
        localHostEnvironmentName,
      );
      expect(describeEnvironmentId(localHostEnvironmentId), isNot('windows'));
    });

    test('leaves any other id alone', () {
      // Only the local host has a key that lies. An SSH row's id is at least a
      // handle on the thing.
      expect(describeEnvironmentId('ssh-build-box'), 'ssh-build-box');
    });
  });
}
