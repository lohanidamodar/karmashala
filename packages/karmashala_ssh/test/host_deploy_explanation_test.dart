import 'package:karmashala_ssh/host.dart';
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

  group('no bundle for the machine', () {
    test(
      'says what the machine is, what this build carries, and the remedy',
      () {
        final said = explainHostDeployment(
          reading(
            HostDeploymentStatus.noBinary,
            platform: arm,
            targets: ['linux-x64'],
          ),
          hostName: 'do-box',
        );

        // The `uname` reading: os, arch and libc.
        expect(said.sentence, contains('do-box'));
        expect(said.sentence, contains('linux/arm64 (glibc)'));
        expect(said.sentence, contains('it carries linux-x64 only'));
        expect(said.remedy, contains('ships the linux-arm64 host bundle'));
        expect(said.action, HostDeployAction.retry);
        expect(said.command, isNull, reason: 'a release cannot build anything');
      },
    );

    test('a build that carries nothing says so — the 2026-09-17 macOS app', () {
      final said = explainHostDeployment(
        reading(HostDeploymentStatus.noBinary, platform: arm),
        hostName: 'do-box',
      );

      expect(said.sentence, contains('it carries none at all'));
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
        // Where `DirectoryHostBinaries.standard` looks second, under a name its
        // pattern accepts.
        expect(
          said.command,
          contains(
            'packages/host/build/karmashala_host-0.0.0-linux-arm64.tar.gz',
          ),
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

      expect(
        '$failure',
        startsWith('This build of Karmashala carries no session host'),
      );
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
