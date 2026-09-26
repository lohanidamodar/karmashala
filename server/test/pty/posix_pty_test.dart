import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

/// The half of the POSIX pty layer with no operating system behind it: how a
/// session's members are found, off a `/proc` a test lays out itself.
void main() {
  group('sessionIdOf', () {
    test('reads field 6 past a comm that holds spaces and parentheses', () {
      expect(sessionIdOf('4242 (sh) S 1 4242 4242 34816 4300 4194560 0'), 4242);
      expect(
        sessionIdOf('4300 (node (claude) x) R 4242 4300 4242 34816 4300 0'),
        4242,
      );
    });

    test('a truncated line is nobody', () {
      expect(sessionIdOf('4242 (sh) S'), isNull);
    });
  });

  group('sessionMembers', () {
    late Directory proc;
    setUp(() => proc = Directory.systemTemp.createTempSync('karmashala-proc'));
    tearDown(() => proc.deleteSync(recursive: true));

    void process(int pid, {required int sid, String comm = 'p'}) {
      Directory('${proc.path}/$pid').createSync();
      File(
        '${proc.path}/$pid/stat',
      ).writeAsStringSync('$pid ($comm) S 1 $pid $sid 0 0');
    }

    test('names every process in the session but the leader, and no other', () {
      process(100, sid: 100, comm: 'sh');
      process(101, sid: 100, comm: 'node');
      process(102, sid: 100, comm: 'a b');
      process(200, sid: 200);
      Directory('${proc.path}/self').createSync();
      File('${proc.path}/uptime').writeAsStringSync('1 1');

      expect(sessionMembers(100, proc: proc)..sort(), [101, 102]);
    });

    test(
      'a process that vanished between the listing and the read is skipped',
      () {
        process(100, sid: 100);
        process(101, sid: 100);
        Directory('${proc.path}/102').createSync(); // no stat: gone already

        expect(sessionMembers(100, proc: proc), [101]);
      },
    );

    test('no /proc means no members, not a fault', () {
      expect(
        sessionMembers(1, proc: Directory('${proc.path}/absent')),
        isEmpty,
      );
    });
  });

  group('childEnvironment', () {
    test('lays the client\'s overrides over the host process\'s own', () {
      final merged = childEnvironment(
        const {'TERM': 'xterm-256color'},
        base: const {
          'PATH': '/usr/bin:/bin',
          'HOME': '/home/d',
          'TERM': 'dumb',
        },
      );

      // The bug this is written for: until 2026-09-16 the child's environment
      // was the overrides *alone*, so a pane that sent only TERM — which is
      // what both the SSH pane and the local-host pane send — ran its shell
      // with no PATH and no HOME.
      expect(merged['PATH'], '/usr/bin:/bin');
      expect(merged['HOME'], '/home/d');
      expect(merged['TERM'], 'xterm-256color', reason: 'the client wins');
    });

    test('an empty override map still inherits everything', () {
      expect(childEnvironment(const {}, base: const {'PATH': '/bin'}), {
        'PATH': '/bin',
      });
    });

    test('names are case-sensitive, unlike the Windows branch', () {
      final merged = childEnvironment(
        const {'path': '/override'},
        base: const {'PATH': '/usr/bin'},
      );
      expect(merged['PATH'], '/usr/bin');
      expect(merged['path'], '/override');
    });

    test('a removed name is withheld even when the host inherited it', () {
      final merged = childEnvironment(
        const {'TERM': 'xterm-256color'},
        base: const {
          'PATH': '/usr/bin',
          'ANTHROPIC_API_KEY': 'from-serve',
          'anthropic_api_key': 'another variable here',
        },
        removed: const {'ANTHROPIC_API_KEY'},
      );
      expect(merged.containsKey('ANTHROPIC_API_KEY'), isFalse);
      expect(
        merged['anthropic_api_key'],
        'another variable here',
        reason:
            'POSIX names are case-sensitive, so this is not the one removed',
      );
      expect(merged['PATH'], '/usr/bin');
    });

    test('a name the client supplies wins over its removal', () {
      final merged = childEnvironment(
        const {'ANTHROPIC_API_KEY': 'set-by-karmashala'},
        base: const {'ANTHROPIC_API_KEY': 'from-serve'},
        removed: const {'ANTHROPIC_API_KEY'},
      );
      expect(merged['ANTHROPIC_API_KEY'], 'set-by-karmashala');
    });
  });
}
