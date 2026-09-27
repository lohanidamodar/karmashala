import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh/files.dart';
import 'package:test/test.dart';

import 'support.dart';

HostKeyRejected rejection() => HostKeyRejected(
  HostKeyPresentation(
    host: 'build-box',
    port: 2222,
    keyType: 'ssh-ed25519',
    fingerprint: 'SHA256:new',
    verdict: HostKeyVerdict.changed,
    known: KnownHostKey(
      host: 'build-box',
      port: 2222,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:old',
      trustedAt: testTime,
    ),
  ),
);

void main() {
  group('finding a refused host key', () {
    test('through the connection wrapper', () {
      final error = SshConnectionException('refused', cause: rejection());
      expect(hostKeyRejectionIn(error)?.verdict, HostKeyVerdict.changed);
    });

    test('through a command runner wrapper as well', () {
      // The same rejection reaches agent discovery two layers deeper. The UI
      // must recognise it there too, without matching on message text.
      final error = CommandException(
        'Cannot run bash',
        cause: SshConnectionException('refused', cause: rejection()),
      );
      expect(hostKeyRejectionIn(error), isNotNull);
    });

    test('and through SFTP browsing', () {
      final error = RemoteBrowseException(
        'Cannot browse',
        cause: SshConnectionException('refused', cause: rejection()),
      );
      expect(hostKeyRejectionIn(error), isNotNull);
    });

    test('an ordinary failure carries no rejection', () {
      expect(hostKeyRejectionIn(SshConnectionException('timeout')), isNull);
      expect(hostKeyRejectionIn(null), isNull);
    });

    test('a cause cycle terminates instead of hanging the UI', () {
      final outer = CommandException('outer');
      final looped = CommandException('looped', cause: outer);
      expect(hostKeyRejectionIn(looped), isNull);
    });
  });

  group('describing a failure', () {
    test('a changed host key describes itself, loudly', () {
      final message = describeSshFailure(
        CommandException('Cannot run bash', cause: rejection()),
      );
      expect(message, contains('REMOTE HOST IDENTIFICATION HAS CHANGED'));
      expect(message, contains('SHA256:old'));
      expect(message, contains('SHA256:new'));
    });

    test('the layer that knows wins over the wrapper around it', () {
      final message = describeSshFailure(
        CommandException(
          'Cannot run bash on dev@build-box:22',
          cause: SshConnectionException(
            'Authentication as dev@build-box was rejected.',
          ),
        ),
      );
      expect(message, 'Authentication as dev@build-box was rejected.');
    });

    test('an unrecognised error still says something', () {
      expect(describeSshFailure(StateError('boom')), contains('boom'));
    });
  });

  group('remote paths', () {
    test('the parent of a nested path', () {
      expect(parentRemotePath('/home/me/src'), '/home/me');
      expect(parentRemotePath('/home/me/src/'), '/home/me');
    });

    test('a top-level directory has the root as its parent', () {
      expect(parentRemotePath('/home'), '/');
    });

    test('the root has none, so "up" can be disabled rather than lie', () {
      expect(parentRemotePath('/'), isNull);
      expect(parentRemotePath(''), isNull);
    });
  });

  group('an error nobody typed for', () {
    test('never leads with the class\'s own words', () {
      expect(describeSshFailure(StateError('no such pane')), 'no such pane');
      expect(
        describeSshFailure(TimeoutException('x', const Duration(seconds: 20))),
        'The machine did not answer in time (20 s).',
      );
      for (final error in <Object>[
        StateError('a'),
        TimeoutException('b'),
        ArgumentError('c'),
      ]) {
        final said = describeSshFailure(error);
        expect(said, isNot(contains('Bad state')));
        expect(said, isNot(contains('TimeoutException')));
        expect(said, isNot(contains('Invalid argument')));
      }
    });
  });
}
