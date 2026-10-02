import 'package:agent_cli/process.dart'
    show EnvironmentKind, ExecutionEnvironment;
import 'package:karmashala_acp/karmashala_acp.dart'
    show AcpRpcError, JsonRpcErrorCodes;
import 'package:karmashala_host/src/acp/acp_path_scope.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Where an agent's `fs/*` paths land: checked in the agent's spelling,
/// mapped to this machine's.
void main() {
  final wsl = ExecutionEnvironment(
    id: 'wsl:archlinux',
    kind: EnvironmentKind.wsl,
    name: 'archlinux',
    wslDistribution: 'archlinux',
    createdAt: DateTime.utc(2026),
  );

  test('a WSL agent\'s POSIX paths are checked as POSIX and land on the '
      'distribution\'s share, not on the current drive', () {
    final scope = AcpPathScope.forEnvironment(wsl, '/tmp/work');
    expect(scope.resolve('/tmp/work/note.txt', verb: 'read'), (
      agent: '/tmp/work/note.txt',
      host: r'\\wsl.localhost\archlinux\tmp\work\note.txt',
    ));
    expect(scope.resolve('sub/../note.txt', verb: 'read'), (
      agent: '/tmp/work/note.txt',
      host: r'\\wsl.localhost\archlinux\tmp\work\note.txt',
    ));
    expect(scope.resolve('/tmp/work', verb: 'read').agent, '/tmp/work');
  });

  test('a WSL agent working on a mounted drive lands on that drive', () {
    final scope = AcpPathScope.forEnvironment(wsl, '/mnt/c/src/repo');
    expect(
      scope.resolve('lib/a.dart', verb: 'written').host,
      r'C:\src\repo\lib\a.dart',
    );
  });

  test('a path outside the working directory is -32602 in words, in the '
      'agent\'s spelling', () {
    final scope = AcpPathScope.forEnvironment(wsl, '/tmp/work');
    for (final outside in ['/etc/passwd', '../other/x', '/tmp/work2/x']) {
      expect(
        () => scope.resolve(outside, verb: 'written'),
        throwsA(
          isA<AcpRpcError>()
              .having((e) => e.code, 'code', JsonRpcErrorCodes.invalidParams)
              .having((e) => e.message, 'message', contains('/tmp/work'))
              .having((e) => e.message, 'message', contains('not written')),
        ),
        reason: outside,
      );
    }
  });

  test('a local environment, or none, keeps this machine\'s own paths', () {
    final root = p.current;
    for (final environment in [
      null,
      ExecutionEnvironment(
        id: 'windows',
        kind: EnvironmentKind.windowsNative,
        name: 'Windows',
        createdAt: DateTime.utc(2026),
      ),
    ]) {
      final scope = AcpPathScope.forEnvironment(environment, root);
      final resolved = scope.resolve('a.txt', verb: 'read');
      expect(resolved.agent, p.join(root, 'a.txt'));
      expect(resolved.host, resolved.agent);
    }
  });
}
