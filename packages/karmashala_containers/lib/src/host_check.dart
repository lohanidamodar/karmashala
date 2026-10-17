/// Measures whether a host can run a container: Docker's answer, the CPU
/// architecture, cores, free memory and free disk. Prints `key=value` lines;
/// read with [parseHostCheck]. Run as `sh -s` with this on stdin.
const hostCheckScript = r'''
echo "user=$(id -un 2>/dev/null)"
echo "arch=$(uname -m)"
echo "cores=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)"
echo "memfree_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)"
if ! command -v docker >/dev/null 2>&1; then
  echo "docker=missing"
  exit 0
fi
out=$(docker version --format '{{.Server.Version}}' 2>&1)
echo "docker_rc=$?"
echo "docker_out=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
[ -d "$root" ] || root=/
echo "diskfree_kb=$(df -Pk "$root" 2>/dev/null | awk 'NR==2 {print $4}')"
''';

/// What a host check found.
class HostCheck {
  const HostCheck({
    required this.canHost,
    this.problem,
    this.dockerVersion,
    this.architecture,
    this.cores,
    this.freeMemoryMb,
    this.freeDiskMb,
  });

  final bool canHost;

  /// Why it cannot, in words a person can act on.
  final String? problem;
  final String? dockerVersion;

  /// `x86_64` or `aarch64`, as `uname -m` says.
  final String? architecture;
  final int? cores;
  final int? freeMemoryMb;
  final int? freeDiskMb;

  /// A failed check that never reached the host.
  const HostCheck.unreachable(String why) : this(canHost: false, problem: why);
}

const _architectures = {'x86_64', 'aarch64', 'arm64'};

/// Reads [hostCheckScript]'s output. [hostName] names the host in a problem.
HostCheck parseHostCheck(String output, {required String hostName}) {
  final values = <String, String>{};
  for (final line in output.split('\n')) {
    final equals = line.indexOf('=');
    if (equals <= 0) continue;
    values[line.substring(0, equals).trim()] = line
        .substring(equals + 1)
        .trim();
  }
  int? number(String key) => int.tryParse(values[key] ?? '');
  int? mb(String key) => switch (number(key)) {
    null => null,
    final kb => kb ~/ 1024,
  };

  final architecture = values['arch'];
  final measured = (
    architecture: architecture,
    cores: number('cores'),
    freeMemoryMb: mb('memfree_kb'),
    freeDiskMb: mb('diskfree_kb'),
  );
  HostCheck cannot(String problem) => HostCheck(
    canHost: false,
    problem: problem,
    architecture: measured.architecture,
    cores: measured.cores,
    freeMemoryMb: measured.freeMemoryMb,
    freeDiskMb: measured.freeDiskMb,
  );

  if (values.isEmpty) return cannot('$hostName did not answer the check.');
  if (values['docker'] == 'missing') {
    return cannot('Docker isn\'t installed on $hostName.');
  }
  final rc = number('docker_rc');
  final said = values['docker_out'] ?? '';
  final lower = said.toLowerCase();
  if (rc != 0) {
    if (lower.contains('permission denied')) {
      final user = values['user'];
      return cannot(
        '${user == null || user.isEmpty ? 'This account' : user} can\'t use '
        'Docker on $hostName: not in the docker group.',
      );
    }
    if (lower.contains('cannot connect') ||
        lower.contains('failed to connect') ||
        lower.contains('is the docker daemon running') ||
        lower.contains('no such file or directory')) {
      return cannot('Docker is installed on $hostName but not running.');
    }
    return cannot(
      'Docker on $hostName answered: '
      '${said.isEmpty ? 'exit code $rc' : said}',
    );
  }
  if (architecture != null && !_architectures.contains(architecture)) {
    return cannot(
      '$hostName is $architecture; containers need x86_64 or '
      'arm64.',
    );
  }
  return HostCheck(
    canHost: true,
    dockerVersion: said.isEmpty ? null : said,
    architecture: measured.architecture,
    cores: measured.cores,
    freeMemoryMb: measured.freeMemoryMb,
    freeDiskMb: measured.freeDiskMb,
  );
}

/// [check] as the wire carries it.
Map<String, Object?> hostCheckToJson(HostCheck check) => {
  'canHost': check.canHost,
  'problem': ?check.problem,
  'dockerVersion': ?check.dockerVersion,
  'architecture': ?check.architecture,
  'cores': ?check.cores,
  'freeMemoryMb': ?check.freeMemoryMb,
  'freeDiskMb': ?check.freeDiskMb,
};

HostCheck hostCheckFromJson(Map<String, Object?> json) => HostCheck(
  canHost: json['canHost'] == true,
  problem: json['problem'] as String?,
  dockerVersion: json['dockerVersion'] as String?,
  architecture: json['architecture'] as String?,
  cores: json['cores'] as int?,
  freeMemoryMb: json['freeMemoryMb'] as int?,
  freeDiskMb: json['freeDiskMb'] as int?,
);
