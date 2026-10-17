import 'package:karmashala_containers/karmashala_containers.dart';
import 'package:test/test.dart';

const _measured = '''
user=karma
arch=x86_64
cores=8
memfree_kb=11744051
''';

void main() {
  test('a host with a running Docker can host, with its figures', () {
    final check = parseHostCheck(
      '${_measured}docker_rc=0\ndocker_out=27.3.1\ndiskfree_kb=77594624\n',
      hostName: 'build-box',
    );
    expect(check.canHost, isTrue);
    expect(check.problem, isNull);
    expect(check.dockerVersion, '27.3.1');
    expect(check.architecture, 'x86_64');
    expect(check.cores, 8);
    expect(check.freeMemoryMb, 11468);
    expect(check.freeDiskMb, 75776);
  });

  test('a permission error says which account and the docker group', () {
    final check = parseHostCheck(
      '${_measured}docker_rc=1\ndocker_out=permission denied while trying to '
      'connect to the Docker daemon socket at unix:///var/run/docker.sock\n',
      hostName: 'pi-lab',
    );
    expect(check.canHost, isFalse);
    expect(
      check.problem,
      "karma can't use Docker on pi-lab: not in the docker group.",
    );
    expect(check.cores, 8, reason: 'what was measured is still shown');
  });

  test('a daemon that is not running is said plainly', () {
    for (final said in [
      'failed to connect to the docker API at unix:///var/run/docker.sock; '
          'check if the path is correct and if the daemon is running: dial '
          'unix /var/run/docker.sock: connect: no such file or directory',
      'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. '
          'Is the docker daemon running?',
    ]) {
      final check = parseHostCheck(
        '${_measured}docker_rc=1\ndocker_out=$said\n',
        hostName: 'archlinux',
      );
      expect(check.canHost, isFalse);
      expect(
        check.problem,
        'Docker is installed on archlinux but not running.',
      );
    }
  });

  test('no Docker at all, and an unknown failure, are told apart', () {
    expect(
      parseHostCheck('${_measured}docker=missing\n', hostName: 'h').problem,
      "Docker isn't installed on h.",
    );
    expect(
      parseHostCheck(
        '${_measured}docker_rc=2\ndocker_out=something odd\n',
        hostName: 'h',
      ).problem,
      'Docker on h answered: something odd',
    );
  });

  test('an unsupported architecture cannot host', () {
    final check = parseHostCheck(
      'arch=armv7l\ndocker_rc=0\ndocker_out=24.0.0\n',
      hostName: 'pi',
    );
    expect(check.canHost, isFalse);
    expect(check.problem, contains('armv7l'));
  });

  test('silence is not a pass', () {
    final check = parseHostCheck('', hostName: 'h');
    expect(check.canHost, isFalse);
    expect(check.problem, 'h did not answer the check.');
  });

  test('a spec is checked against what the host has', () {
    const spec = ContainerSpec(
      name: 'sandbox',
      distro: ContainerDistro.ubuntu2404,
      cpus: 4,
      memoryMb: 4096,
    );
    expect(containerSpecProblem(spec, cores: 8, freeMemoryMb: 8000), isNull);
    expect(containerSpecProblem(spec, cores: 2), 'The host has 2 CPUs.');
    expect(
      containerSpecProblem(spec, freeMemoryMb: 2048),
      'The host has 2 GB free.',
    );
    expect(containerNameProblem('Bad Name'), isNotNull);
    expect(containerNameProblem('-x'), isNotNull);
    expect(containerNameProblem('dev-1.box_2'), isNull);
    expect(formatMemory(11468), '11.2 GB');
    expect(formatMemory(512), '512 MB');
  });
}
