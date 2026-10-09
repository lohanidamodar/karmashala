import 'package:agent_cli/process.dart'
    show EnvironmentKind, EnvironmentPath, ExecutionEnvironment;
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

  test('a WSL agent\'s backslash is refused: one name to it, a separator '
      'on the share it lands on', () {
    final scope = AcpPathScope.forEnvironment(wsl, '/mnt/c/src/repo');
    for (final escaping in [
      r'..\..\..\Windows\x',
      r'/mnt/c/src/repo/..\..\x',
    ]) {
      expect(
        () => scope.resolve(escaping, verb: 'written'),
        throwsA(
          isA<AcpRpcError>().having(
            (e) => e.code,
            'code',
            JsonRpcErrorCodes.invalidParams,
          ),
        ),
        reason: escaping,
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

  group('checkouts attached to the session', () {
    var attached = <EnvironmentPath>[];
    setUp(() => attached = []);

    AcpPathScope wslScope() => AcpPathScope.forEnvironment(
      wsl,
      '/home/u/scratch',
      environmentId: wsl.id,
      checkouts: () => attached,
    );

    test('one in the same distribution is inside the scope, and lands on '
        'its share', () {
      final scope = wslScope();
      attached = [EnvironmentPath(environmentId: wsl.id, path: '/home/u/far')];
      expect(scope.resolve('/home/u/far/lib/a.dart', verb: 'read'), (
        agent: '/home/u/far/lib/a.dart',
        host: r'\\wsl.localhost\archlinux\home\u\far\lib\a.dart',
      ));
      expect(scope.attachedRoots, ['/home/u/far']);
      // Relative paths stay the working directory's.
      expect(
        scope.resolve('note.txt', verb: 'read').agent,
        '/home/u/scratch/note.txt',
      );
    });

    test('a Windows checkout is spelled as its mount for a WSL agent', () {
      final scope = wslScope();
      attached = [
        const EnvironmentPath(environmentId: 'windows', path: r'C:\src\other'),
      ];
      expect(scope.attachedRoots, ['/mnt/c/src/other']);
      expect(
        scope.resolve('/mnt/c/src/other/x.txt', verb: 'written').host,
        r'C:\src\other\x.txt',
      );
    });

    test('follows a detach at once: the same path is refused in words', () {
      final scope = wslScope();
      attached = [EnvironmentPath(environmentId: wsl.id, path: '/home/u/far')];
      scope.resolve('/home/u/far/a', verb: 'read');
      attached = [];
      expect(
        () => scope.resolve('/home/u/far/a', verb: 'read'),
        throwsA(
          isA<AcpRpcError>()
              .having((e) => e.code, 'code', JsonRpcErrorCodes.invalidParams)
              .having((e) => e.message, 'message', contains('attached')),
        ),
      );
    });

    test('one this agent has no name for is not a root', () {
      final scope = wslScope();
      attached = [
        const EnvironmentPath(environmentId: 'ssh:box', path: '/srv/app'),
        EnvironmentPath(environmentId: wsl.id, path: '/home/u/scratch/sub'),
      ];
      expect(scope.attachedRoots, isEmpty);
      expect(
        () => scope.resolve('/srv/app/x', verb: 'read'),
        throwsA(isA<AcpRpcError>()),
      );
    });

    test('a checkout the store cannot list leaves the working directory', () {
      final scope = AcpPathScope.forEnvironment(
        wsl,
        '/home/u/scratch',
        environmentId: wsl.id,
        checkouts: () => throw StateError('store closed'),
      );
      expect(scope.attachedRoots, isEmpty);
      expect(scope.resolve('a', verb: 'read').agent, '/home/u/scratch/a');
    });
  });
}
