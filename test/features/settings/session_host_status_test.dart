import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/presentation/session_host_status_line.dart';
import 'package:karmashala_ssh/host.dart';

/// The three facts the supervisor row has to carry, and the one it must refuse
/// to invent.
///
/// A pure function so the sentence can be asserted without a widget tree —
/// what matters here is what it *says*, and a golden of a row would pin the
/// padding instead.
void main() {
  final now = DateTime.utc(2026, 9, 9, 12, 0);

  test(
    'nothing checked is said as nothing checked, never as "not running"',
    () {
      expect(
        sessionHostStatusText(null, now: now),
        'Nothing has been checked yet.',
      );
    },
  );

  test('a running host names its version, who started it, and the age', () {
    final line = sessionHostStatusText(
      HostDeployment(
        status: HostDeploymentStatus.ready,
        observedAt: DateTime.utc(2026, 9, 9, 11, 58),
        reason: 'answering',
        hostVersion: '0.1.0',
        restartedByUs: true,
      ),
      now: now,
    );
    expect(line, contains('karmashala_host 0.1.0 is running'));
    expect(line, contains('started by this app'));
    expect(line, contains('checked 2m ago'));
  });

  test(
    'a host we did not start says so, which is the whole supervisor story',
    () {
      final line = sessionHostStatusText(
        HostDeployment(
          status: HostDeploymentStatus.ready,
          observedAt: now,
          reason: 'answering',
          hostVersion: '0.1.0',
        ),
        now: now,
      );
      expect(line, contains('not started by this app'));
      expect(line, contains('checked just now'));
    },
  );

  test('nothing listening is "no host is running", with its age', () {
    final line = sessionHostStatusText(
      HostDeployment(
        status: HostDeploymentStatus.unknown,
        observedAt: DateTime.utc(2026, 9, 9, 9, 0),
        reason: 'Nothing is listening on the socket.',
      ),
      now: now,
    );
    expect(line, contains('No session host is running here'));
    expect(line, contains('checked 3h ago'));
  });

  test('any other refusal is shown in its own words, with its age', () {
    final line = sessionHostStatusText(
      HostDeployment(
        status: HostDeploymentStatus.noBinary,
        observedAt: DateTime.utc(2026, 9, 8, 12, 0),
        reason: 'No karmashala_host.exe beside this app.',
      ),
      now: now,
    );
    expect(line, startsWith('No karmashala_host.exe beside this app.'));
    expect(line, contains('checked 1d ago'));
  });
}
