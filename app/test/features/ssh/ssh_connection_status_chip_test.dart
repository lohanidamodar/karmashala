import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala/src/features/ssh/presentation/ssh_connection_status_chip.dart';
import 'package:flutter_test/flutter_test.dart';

/// How the server's connection state reads on the chip. What a failure says
/// is `karmashala_ssh`'s (its `ssh_failure_test`).
void main() {
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
}
