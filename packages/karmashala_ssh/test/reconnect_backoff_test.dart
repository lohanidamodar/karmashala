import 'package:karmashala_ssh/connection.dart';
import 'package:test/test.dart';

void main() {
  group('reconnectBackoff', () {
    test('the first attempt waits nothing', () {
      expect(reconnectBackoff(0), Duration.zero);
    });

    test('doubles per attempt', () {
      expect(reconnectBackoff(1), const Duration(milliseconds: 500));
      expect(reconnectBackoff(2), const Duration(seconds: 1));
      expect(reconnectBackoff(3), const Duration(seconds: 2));
      expect(reconnectBackoff(4), const Duration(seconds: 4));
    });

    test('is capped so a long outage never waits absurdly', () {
      expect(reconnectBackoff(7), const Duration(seconds: 30));
      expect(reconnectBackoff(50), const Duration(seconds: 30));
    });
  });

  group('SshConnectionState', () {
    test('only connected counts as connected', () {
      for (final status in SshConnectionStatus.values) {
        expect(
          SshConnectionState(status: status).isConnected,
          status == SshConnectionStatus.connected,
        );
      }
    });
  });
}
