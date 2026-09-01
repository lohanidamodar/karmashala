import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/logging/diagnostics.dart';
import 'package:karmashala/src/core/logging/diagnostics_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala/src/features/settings/presentation/diagnostics_page.dart';
import 'package:karmashala/src/features/settings/presentation/watch_set_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Settings → Diagnostics has to answer one question: **is anything silently
/// not being watched?**
///
/// The P0 this replaced was a status watcher that capped its watch set at 60
/// sessions. It survived to production because nobody could tell, and the
/// coverage that now makes it tellable reached only the log file.
void main() {
  const healthy = SessionStatusCoverage(
    tracked: 12,
    hookAnswered: 9,
    probeCandidates: 3,
    probed: 3,
    neverProbed: 0,
    probeFailures: 0,
    rotationPeriod: Duration(seconds: 8),
  );

  Future<void> pumpPage(
    WidgetTester tester,
    SessionStatusCoverage? coverage,
  ) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        diagnosticsProvider.overrideWithValue(
          Diagnostics(echoToConsole: false),
        ),
        sessionStatusCoverageProvider.overrideWith(
          (ref) => Stream.value(coverage),
        ),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: DiagnosticsPage())),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('says how many sessions are watched and who answers for them', (
    tester,
  ) async {
    await pumpPage(tester, healthy);

    expect(find.text('12'), findsOneWidget);
    expect(find.text('9 of 12'), findsOneWidget);
    expect(find.textContaining('3 were read'), findsOneWidget);
  });

  testWidgets('states the rotation as the promise it is', (tester) async {
    await pumpPage(tester, healthy);

    // The guaranteed worst case for coming back round to an unhooked session —
    // the number that turns "we are watching" into "and getting round to it".
    expect(find.text('every 8s'), findsOneWidget);
  });

  testWidgets('a rotation that has fallen behind says so in words', (
    tester,
  ) async {
    await pumpPage(
      tester,
      const SessionStatusCoverage(
        tracked: 900,
        hookAnswered: 10,
        probeCandidates: 890,
        probed: 24,
        neverProbed: 400,
        probeFailures: 0,
        rotationPeriod: Duration(seconds: 150),
      ),
    );

    expect(find.textContaining('behind'), findsOneWidget);
  });

  testWidgets('a rotation that cannot happen at all is not "0s"', (
    tester,
  ) async {
    await pumpPage(
      tester,
      const SessionStatusCoverage(
        tracked: 4,
        hookAnswered: 0,
        probeCandidates: 4,
        probed: 0,
        neverProbed: 4,
        probeFailures: 0,
        rotationPeriod: null,
      ),
    );

    expect(find.text('never'), findsOneWidget);
  });

  testWidgets('before the first cycle it says so rather than showing zeros', (
    tester,
  ) async {
    await pumpPage(tester, null);

    expect(find.textContaining('Nothing measured yet'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('a healthy pass does not mention failed reads', (tester) async {
    await pumpPage(tester, healthy);

    expect(find.textContaining('could not be read'), findsNothing);
  });

  testWidgets('a read that failed is named, because it is not a queue', (
    tester,
  ) async {
    await pumpPage(
      tester,
      const SessionStatusCoverage(
        tracked: 12,
        hookAnswered: 9,
        probeCandidates: 3,
        probed: 3,
        neverProbed: 0,
        probeFailures: 2,
        rotationPeriod: Duration(seconds: 8),
      ),
    );

    expect(find.textContaining('could not be read'), findsOneWidget);
  });
}
