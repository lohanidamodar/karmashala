import 'package:karmashala_ssh_host/host.dart';
import 'package:test/test.dart';

import 'host_deployer_test.dart' show FakeBinaries, FakeTarget, deployerFor;

void main() {
  HostDeployment reading(
    HostDeploymentStatus status, {
    String reason = 'Something the machine said.',
    HostPlatform? platform,
    List<String> targets = const [],
    PrivilegedCommand? privileged,
  }) => HostDeployment(
    status: status,
    observedAt: DateTime.utc(2026, 9, 17),
    reason: reason,
    platform: platform,
    availableTargets: targets,
    privileged: privileged,
  );

  final arm = HostPlatform(
    operatingSystem: 'linux',
    architecture: 'arm64',
    libc: HostLibc.glibc,
    observedAt: DateTime.utc(2026, 9, 17),
  );

  group('what a pane says, in short', () {
    test('names the machine and what to do — never its address or the '
        'folders searched', () {
      final said = hostDeploymentInShort(
        reading(
          HostDeploymentStatus.noBinary,
          platform: arm,
          reason: 'dev@203.0.113.9:22 is linux-arm64 … it looked in /srv/b',
        ),
        hostName: 'DO',
      );
      expect(
        said,
        "Can't open a terminal on DO: this Karmashala has no host for "
        'linux-arm64. Update Karmashala, then Retry.',
      );
    });

    test('every status is one or two short sentences', () {
      for (final status in HostDeploymentStatus.values) {
        final said = hostDeploymentInShort(
          reading(
            status,
            platform: arm,
            reason: 'a long account that mentions /srv/b and 203.0.113.9',
          ),
          hostName: 'DO',
        );
        expect(said.length, lessThan(160), reason: status.name);
        expect(said, isNot(contains('203.0.113.9')), reason: status.name);
        expect(said, isNot(contains('/srv/b')), reason: status.name);
      }
    });

    test('a failure keeps the whole account as its text', () {
      final failure = HostDeployFailure(
        hostName: 'DO',
        deployment: reading(
          HostDeploymentStatus.noBinary,
          platform: arm,
          reason: 'it looked in /srv/b',
        ),
      );
      expect(failure.inShort, startsWith("Can't open a terminal on DO"));
      expect('$failure', contains('/srv/b'));
    });
  });

  group('no bundle for the machine', () {
    test('says the deployer\'s own words, and where the server wants the '
        'bundle put (slice 5d)', () {
      final said = explainHostDeployment(
        reading(
          HostDeploymentStatus.noBinary,
          platform: arm,
          targets: ['linux-x64'],
        ),
        hostName: 'do-box',
      );

      expect(said.sentence, 'Something the machine said.');
      expect(said.remedy, contains('linux-arm64 host bundle'));
      expect(said.remedy, contains('where the Karmashala server looks'));
      expect(said.action, HostDeployAction.retry);
      expect(said.command, isNull, reason: 'a release cannot build anything');
    });

    test('the deployer says what the machine is, where the server looked and '
        'what it has', () async {
      final target = FakeTarget(uname: 'Linux\naarch64\nldd (GNU libc) 2.36\n');

      final deployment = await deployerFor(target).deploy();

      expect(deployment.reason, contains('linux-arm64'));
      expect(deployment.reason, contains('the fake bundle folder'));
      expect(deployment.reason, contains('it has linux-x64'));
    });

    test('a musl box is refused in words, with no tmux to fall back on', () {
      final said = explainHostDeployment(
        reading(HostDeploymentStatus.unsupportedPlatform, platform: arm),
        hostName: 'do-box',
      );
      expect(said.remedy, contains('glibc Linux and macOS only'));
      expect(said.remedy, isNot(contains('tmux')));
      expect(said.action, HostDeployAction.none);
    });

    test(
      'a debug run gets the command that builds it, where it is looked for',
      () {
        final said = explainHostDeployment(
          reading(HostDeploymentStatus.noBinary, platform: arm),
          hostName: 'do-box',
          debugRun: true,
        );

        expect(said.remedy, contains('debug run'));
        expect(said.command, contains('dart build cli'));
        expect(said.command, contains('--target-arch=arm64'));
        // `compile exe` refuses a target with a build hook (§22).
        expect(said.command, isNot(contains('compile exe')));
        // Where the server looks on a debug run, under a name its pattern
        // accepts.
        expect(
          said.command,
          contains('server/build/karmashala_host-0.0.0-linux-arm64.tar.gz'),
        );
      },
    );

    test('the deployer fills in what the build carries', () async {
      final target = FakeTarget(uname: 'Linux\naarch64\nldd (GNU libc) 2.36\n');

      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.noBinary);
      expect(deployment.availableTargets, ['linux-x64']);
      expect(deployment.platform?.targetKey, 'linux-arm64');
    });
  });

  test('a stale host with nothing newer never blames "this build"', () {
    // The server searches every folder it reads bundles from, so "this build
    // carries no newer host" was false whenever another folder held one.
    final deployment = HostDeployment(
      status: HostDeploymentStatus.protocolMismatch,
      observedAt: DateTime.utc(2026, 10, 8),
      reason: 'The host speaks an older protocol.',
      platform: arm,
      noNewerHost: true,
      offeredVersion: '1.29.0',
      bundleFolder: '/data/host-bundles',
    );

    final said = explainHostDeployment(deployment, hostName: 'do-box');
    final short = hostDeploymentInShort(deployment, hostName: 'do-box');

    expect(said.remedy, isNot(contains('This build')));
    expect(
      said.remedy,
      contains(
        'No folder the Karmashala server reads host bundles from holds a '
        'host for linux-arm64 newer than the 1.29.0 on do-box',
      ),
    );
    expect(said.remedy, contains('/data/host-bundles'));
    expect(short, isNot(contains('this Karmashala has no newer one')));
    expect(short, contains('the server has no newer one'));
  });

  test('every failure is a sentence, a remedy and a button — never a dump', () {
    for (final status in HostDeploymentStatus.values) {
      if (status == HostDeploymentStatus.ready) continue;
      final said = explainHostDeployment(
        reading(status, platform: arm),
        hostName: 'do-box',
      );

      expect(said.sentence, isNotEmpty, reason: status.name);
      expect(said.remedy, isNotEmpty, reason: status.name);
      expect('${said.sentence} ${said.remedy}', isNot(contains('Bad state')));
      expect(
        said.action == HostDeployAction.none,
        status == HostDeploymentStatus.unsupportedPlatform,
        reason: 'only a machine the host cannot run on has nothing to press',
      );
    }
  });

  test(
    'the failure thrown in place of a StateError reads as a person would say it',
    () {
      final failure = HostDeployFailure(
        hostName: 'do-box',
        deployment: reading(HostDeploymentStatus.noBinary, platform: arm),
      );

      expect('$failure', startsWith('Something the machine said.'));
      expect('$failure', isNot(contains('Bad state')));
      expect('$failure', isNot(contains('HostDeployFailure')));
    },
  );

  group('a machine missing what the host needs', () {
    test(
      'no tar is a package to install in a terminal, and nothing is uploaded',
      () async {
        final target = FakeTarget();
        target.scripted['for t in tar setsid'] = const RemoteRun(
          0,
          'missing=tar\npm=apt-get\nuid=1000\n',
          '',
        );

        final deployment = await deployerFor(
          target,
          binaries: FakeBinaries(isBundleArchive: true),
        ).deploy();

        expect(deployment.status, HostDeploymentStatus.cannotInstall);
        expect(deployment.reason, contains('`tar`'));
        expect(deployment.reason, contains('Nothing was uploaded'));
        expect(deployment.privileged?.command, 'sudo apt-get install -y tar');
        expect(target.uploads, isEmpty);

        final said = explainHostDeployment(deployment, hostName: 'do-box');
        expect(said.privileged, deployment.privileged);
        expect(said.remedy, contains('terminal on do-box'));
        expect(said.action, HostDeployAction.install);
      },
    );

    test('no setsid names util-linux, and root is not told to sudo', () async {
      final target = FakeTarget();
      target.scripted['for t in setsid'] = const RemoteRun(
        0,
        'missing=setsid\npm=dnf\nuid=0\n',
        '',
      );

      final deployment = await deployerFor(target).deploy();

      expect(deployment.privileged?.command, 'dnf install -y util-linux');
    });

    test(
      'a package manager this does not know still says what is missing',
      () async {
        final target = FakeTarget();
        target.scripted['for t in setsid'] = const RemoteRun(
          0,
          'missing=setsid\nuid=1000\n',
          '',
        );

        final deployment = await deployerFor(target).deploy();

        expect(deployment.status, HostDeploymentStatus.cannotInstall);
        expect(deployment.privileged, isNull);
        expect(deployment.reason, contains('util-linux'));
      },
    );

    test('an installed host is never asked about its tools', () async {
      final target = FakeTarget()..existingSize = 1024;

      await deployerFor(target).deploy();

      expect(target.commands.where((c) => c.contains('for t in')), isEmpty);
    });
  });
}
