import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/backup/application/backup_client.dart';
import 'package:karmashala/src/features/backup/presentation/data_backup_section.dart';
import 'package:karmashala/src/features/backup/presentation/data_restore_section.dart';
import 'package:karmashala_host/lifecycle_client.dart' show ServerMethod;
import 'package:karmashala_host_protocol/protocol.dart' show kBackupExclusions;

import '../../support/window_matrix.dart';

/// Settings → Data: backing up now and on a schedule, what a backup leaves
/// out, and a backup shown before it is restored.
void main() {
  Map<String, Object?> schedule({
    String frequency = 'off',
    String? folder = r'C:\backups',
    bool pending = false,
  }) => {
    'frequency': frequency,
    'keep': 7,
    'folder': ?folder,
    'newest': '2026-10-08T09:00:00.000Z',
    'pendingRestore': pending,
    'lastRestore': {
      'restoredAt': '2026-10-01T10:00:00.000Z',
      'backupCreatedAt': '2026-09-30T10:00:00.000Z',
      'before': r'C:\data.before-restore-20261001-100000',
    },
  };

  const summaryJson = <String, Object?>{
    'appVersion': '1.34.4',
    'schemaVersion': 90,
    'createdAt': '2026-10-08T09:00:00.000Z',
    'dataDirectory': r'C:\Users\someone\.karmashala',
    'counts': {'sessions': 12, 'projects': 3, 'session_artifacts': 1},
    'fileCount': 40,
    'fileBytes': 2048,
    'checkpoints': [
      {'repositoryPath': '/a', 'ref': 'refs/karmashala/checkpoints/s1'},
      {'repositoryPath': '/a', 'ref': 'refs/karmashala/checkpoints/s2'},
    ],
    'skipped': ['attachments/.env'],
  };

  late List<(String, Map<String, Object?>)> calls;
  late Map<String, Object?> current;

  Widget app({Widget? child}) {
    final container = ProviderContainer(
      overrides: [
        backupClientProvider.overrideWithValue(
          BackupClient((method, [arguments = const {}]) async {
            calls.add((method, arguments));
            if (method == ServerMethod.backupScheduleSet) {
              current = schedule(
                frequency: arguments['frequency']! as String,
                folder: arguments['folder'] as String?,
              );
            }
            return current;
          }),
        ),
      ],
    );
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child:
                child ??
                const Column(
                  children: [DataBackupSection(), DataRestoreSection()],
                ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    calls = [];
    current = schedule();
  });

  testWidgets('names exactly what a backup leaves out', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    for (final line in kBackupExclusions) {
      expect(find.text('• $line'), findsOneWidget);
    }
    expect(find.text(r'C:\backups'), findsOneWidget);
    expect(find.textContaining('newest backup there is from'), findsOneWidget);
    expect(find.textContaining('Last restored'), findsOneWidget);
  });

  testWidgets('a schedule is set at the server, with its folder', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('data-backup-frequency')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weekly').last);
    await tester.pumpAndSettle();
    final set = calls.where((c) => c.$1 == ServerMethod.backupScheduleSet);
    expect(set.single.$2, {
      'frequency': 'weekly',
      'keep': 7,
      'folder': r'C:\backups',
    });
  });

  testWidgets('a staged restore offers the restart that switches it in', (
    tester,
  ) async {
    current = schedule(pending: true);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.textContaining('A restore is ready'), findsOneWidget);
    expect(find.text('Restart server'), findsOneWidget);
  });

  group('the preview', () {
    Future<bool?> open(WidgetTester tester, {String? refusal}) async {
      bool? answer;
      await tester.pumpWidget(
        app(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () async => answer = await showBackupPreview(
                context,
                summary: BackupSummary.fromJson(summaryJson),
                refusal: refusal,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('shows what the backup holds and asks', (tester) async {
      await open(tester);
      expect(find.textContaining('12 sessions, 3 projects'), findsOneWidget);
      expect(find.textContaining('40 files'), findsOneWidget);
      expect(
        find.textContaining('2 checkpoint refs in 1 repository'),
        findsOneWidget,
      );
      expect(find.textContaining('looks like a secret'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('data-restore-confirm')),
        findsOneWidget,
      );
    });

    testWidgets('a refused backup says why and cannot be restored', (
      tester,
    ) async {
      await open(
        tester,
        refusal: 'This backup is from a newer Karmashala. Update Karmashala.',
      );
      expect(find.textContaining('from a newer Karmashala'), findsOneWidget);
      expect(find.byKey(const ValueKey('data-restore-confirm')), findsNothing);
      expect(find.text('Close'), findsOneWidget);
    });
  });

  testWidgets('fits from a phone to a desktop, and at large text', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(
      tester,
      build: app,
      matrix: const [
        WindowCell('360x740 (phone)', Size(360, 740)),
        WindowCell('360x740 @ 1.6x text', Size(360, 740), textScale: 1.6),
        desktopWindow,
        WindowCell('720x560 @ 1.6x text', Size(720, 560), textScale: 1.6),
      ],
      checkFocus: false,
      because: 'Settings → Data is drawn at every window size',
    );
  });
}
