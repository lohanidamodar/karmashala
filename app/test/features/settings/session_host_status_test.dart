import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_host/host_paths.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:karmashala/src/features/settings/presentation/session_host_status_line.dart';
import 'package:karmashala_host_protocol/host_access.dart';

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

  test('an outdated host says so, what it holds, and where new panes go', () {
    final line = sessionHostStatusText(
      HostDeployment(
        status: HostDeploymentStatus.ready,
        observedAt: DateTime.utc(2026, 9, 9, 11, 59),
        reason: 'older',
        hostVersion: '0.1.0',
        hostOutdated: true,
        liveSessionIds: const ['a', 'b'],
      ),
      now: now,
    );
    expect(line, contains('An older session host'));
    expect(line, contains('2 running session(s)'));
    expect(line, contains('new terminals run inside the app'));
    expect(line, isNot(contains('0.1.0 is running')));
    expect(line, contains('checked 1m ago'));
  });

  test('an outdated host that would not say what it holds says that', () {
    final line = sessionHostStatusText(
      HostDeployment(
        status: HostDeploymentStatus.ready,
        observedAt: now,
        reason: 'older',
        hostOutdated: true,
      ),
      now: now,
    );
    expect(line, contains('would not say how many sessions it holds'));
  });

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

  test('a host that holds the socket and will not answer is not "none"', () {
    final line = sessionHostStatusText(
      HostDeployment(
        status: HostDeploymentStatus.unknown,
        observedAt: DateTime.utc(2026, 9, 9, 11, 59),
        reason: 'Could not finish the handshake',
        hostUnresponsive: true,
      ),
      now: now,
    );
    // The row said this on 2026-09-24, over a host wedged for three hours.
    expect(line, isNot(contains('No session host is running here')));
    expect(line, contains('did not answer'));
    expect(line, contains('checked 1m ago'));
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

  // Restart and Stop moved to Settings → Server's controls row, which asks
  // first every time (server_status_section_test).
  group('the line', () {
    Future<_FakeAccess> pumpLine(WidgetTester tester, HostDeployment r) async {
      final access = _FakeAccess(r);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localHostSessionAccessProvider.overrideWithValue(access),
            // No supervisor: these are the row's own readings and actions.
          ],
          child: const MaterialApp(
            home: Scaffold(body: SessionHostStatusLine()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return access;
    }

    final start = find.byKey(const ValueKey('session-host-start'));

    testWidgets('a running host offers Sessions and Check, not Restart', (
      tester,
    ) async {
      await pumpLine(
        tester,
        HostDeployment(
          status: HostDeploymentStatus.ready,
          observedAt: DateTime.now(),
          reason: 'current',
        ),
      );
      expect(find.text('Sessions'), findsOneWidget);
      expect(find.text('Check'), findsOneWidget);
      expect(find.text('Restart'), findsNothing);
      expect(find.text('Stop'), findsNothing);
    });

    testWidgets('a host that will not answer is offered no Start', (
      tester,
    ) async {
      final access = await pumpLine(
        tester,
        HostDeployment(
          status: HostDeploymentStatus.unknown,
          observedAt: DateTime.now(),
          reason: 'silent',
          hostUnresponsive: true,
        ),
      );
      expect(start, findsNothing);
      expect(access.listed, 0);
    });

    testWidgets('Start is offered when no host is running, and starts one', (
      tester,
    ) async {
      final access = await pumpLine(
        tester,
        HostDeployment(
          status: HostDeploymentStatus.unknown,
          observedAt: DateTime.now(),
          reason: 'Nothing is listening',
        ),
      );
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(access.starts, 1);
      expect(find.textContaining('is running'), findsOneWidget);
    });

    testWidgets('nothing to start when no host can run', (tester) async {
      await pumpLine(
        tester,
        HostDeployment(
          status: HostDeploymentStatus.noBinary,
          observedAt: DateTime.now(),
          reason: 'No karmashala_host beside this app.',
        ),
      );
      expect(start, findsNothing);
      expect(find.text('Check'), findsOneWidget);
    });
  });
}

/// Answers the readings a test chooses; starts and stops nothing.
class _FakeAccess extends LocalHostSessionAccess {
  _FakeAccess(this.reading)
    : super(paths: HostPaths(Directory.systemTemp.createTempSync('ks-status')));

  HostDeployment reading;
  var starts = 0;
  var listed = 0;

  @override
  Future<List<String>?> liveSessionIds() async {
    listed++;
    return const [];
  }

  @override
  Future<HostDeployment> deployment() async {
    starts++;
    return reading = HostDeployment(
      status: HostDeploymentStatus.ready,
      observedAt: DateTime.now(),
      reason: 'started',
      restartedByUs: true,
    );
  }

  @override
  Future<HostDeployment> observe() async => reading;
}
