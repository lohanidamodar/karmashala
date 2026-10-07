import 'dart:io';

import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// A proposal is filed in the inbox, filed again at every start — the inbox
/// is not kept across one — and stops being a proposal once a person turns
/// it on.
void main() {
  final now = DateTime.utc(2026, 10, 7, 12);
  late AppDatabase db;
  late Directory data;
  late SessionRegistry registry;
  late List<InboxItem> raised;

  DaemonAutomations daemon() => DaemonAutomations(
    database: db,
    registry: registry,
    dataDirectory: data.path,
    mcp: SessionMcpAccessPoint(mcp: null, configDirectory: data.path),
    tell: (_) {},
    clock: () => now,
    timer: ManualAutomationTimer(),
    windows: false,
    raise: raised.add,
  );

  setUp(() {
    raised = [];
    db = AppDatabase.memory();
    db.execute('PRAGMA foreign_keys = OFF;');
    data = Directory.systemTemp.createTempSync('proposals-');
    registry = SessionRegistry(launcher: FakePtyLauncher(), clock: () => now);
    AutomationDao(db).insert(
      Automation(
        id: 'p1',
        repositoryId: 'r1',
        name: 'Nightly',
        schedule: const AutomationSchedule.cron('0 3 * * *'),
        agentInstallationId: 'a1',
        prompt: 'run the tests',
        permissionMode: null,
        enabled: false,
        armedAt: now,
        proposedBy: 'Claude Code in "Fix the cart"',
        proposedSessionId: 's1',
      ),
    );
  });

  tearDown(() async {
    await registry.shutdown();
    db.close();
    data.deleteSync(recursive: true);
  });

  test('a proposal is filed at start, under its own id', () async {
    final automations = daemon();
    await automations.start(const Stream.empty());
    final item = raised.single;
    expect(item.kind, InboxItemKind.automationProposed);
    expect(item.id, proposalInboxId('p1'));
    expect(item.detail, contains('Claude Code in "Fix the cart" proposed'));
    await automations.close();
  });

  test('turned on, it is the owner\'s and no longer a proposal', () async {
    AutomationDao(db).setEnabled('p1', enabled: true);
    final turnedOn = AutomationDao(db).getById('p1')!;
    expect(turnedOn.enabled, isTrue);
    expect(turnedOn.isProposed, isFalse);
    final automations = daemon();
    await automations.start(const Stream.empty());
    expect(raised, isEmpty);
    await automations.close();
  });

  test('paused again, it stays the owner\'s', () {
    final dao = AutomationDao(db)
      ..setEnabled('p1', enabled: true)
      ..setEnabled('p1', enabled: false);
    expect(dao.getById('p1')!.isProposed, isFalse);
    expect(dao.proposed(), isEmpty);
  });
}
