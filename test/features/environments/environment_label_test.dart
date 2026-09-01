/// One vocabulary for naming an execution environment, shared by the desktop's
/// New project dropdown and by what the phone is told over the wire — so a
/// user who reads "WSL · Ubuntu" on one surface never meets a different
/// spelling of the same machine on the other.
library;

import 'package:karmashala/src/features/environments/domain/environment_label.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

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
}
