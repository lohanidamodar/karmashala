import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/ssh/application/ssh_connection_providers.dart';
import 'package:chitragupta/src/features/ssh/application/ssh_failure.dart';
import 'package:chitragupta/src/features/ssh/data/remote_file_browser.dart';
import 'package:chitragupta/src/features/ssh/data/ssh_connection.dart';
import 'package:chitragupta/src/features/ssh/domain/remote_directory_entry.dart';
import 'package:chitragupta/src/features/ssh/domain/ssh_connection_state.dart';
import 'package:chitragupta/src/features/ssh/domain/ssh_host_key.dart';
import 'package:chitragupta/src/features/ssh/presentation/ssh_connection_status_chip.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

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

  group('connection status wording', () {
    test('idle and failed are never the same words', () {
      // A machine nobody has tried and a machine that refused us mean opposite
      // things; collapsing them is how a broken host looks fine.
      final idle = describeSshStatus(const SshConnectionState.idle());
      final failed = describeSshStatus(
        const SshConnectionState(
          status: SshConnectionStatus.failed,
          error: 'nope',
        ),
      );
      expect(idle.label, 'Not connected');
      expect(failed.label, 'Failed');
      expect(idle.icon, isNot(failed.icon));
    });

    test('a scheduled reconnect says when', () {
      final described = describeSshStatus(
        const SshConnectionState(
          status: SshConnectionStatus.disconnected,
          attempt: 2,
          nextRetryIn: Duration(seconds: 2),
        ),
      );
      expect(described.label, 'Reconnecting in 2.0 s');
    });

    test('retries are counted out loud', () {
      expect(
        describeSshStatus(
          const SshConnectionState(
            status: SshConnectionStatus.connecting,
            attempt: 2,
          ),
        ).label,
        'Connecting… (attempt 3)',
      );
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

  group('probe results', () {
    test('a success carries what the remote said', () {
      const probe = SshHostProbe.success(message: 'Linux 6.18.0');
      expect(probe.connected, isTrue);
      expect(probe.message, 'Linux 6.18.0');
    });
  });
}
