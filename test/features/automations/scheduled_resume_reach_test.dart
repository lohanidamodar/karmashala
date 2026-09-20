import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart'
    show formatResetClock;
import 'package:karmashala/src/features/automations/application/scheduled_resume_providers.dart';
import 'package:karmashala/src/features/mcp/inventory_tools.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/remote/application/remote_session_snapshots.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';

import 'scheduled_resume_harness.dart';

/// How far a waiting resume reaches beyond the desktop's own surfaces: an
/// agent may *see* one, a paired phone is told, and neither can arm one.
void main() {
  late ResumeHarness h;

  setUp(() {
    h = ResumeHarness();
    h.addSession();
  });
  tearDown(() => h.dispose());

  ResumeRequest inTwoHours() => ResumeRequest(
    sessionId: 's1',
    fireAt: h.now.add(const Duration(hours: 2)),
  );

  test(
    'list_sessions shows a waiting resume, and nothing when none waits',
    () async {
      final tools = InventoryTools(h.container);
      Future<Map<String, dynamic>> row() async =>
          ((await tools.call('list_sessions', const {}))! as List)
              .cast<Map<String, dynamic>>()
              .single;

      expect(await row(), isNot(contains('scheduledResume')));
      final resume = h.controller.schedule(inTwoHours());
      expect((await row())['scheduledResume'], {
        'state': 'pending',
        'fireAt': resume.fireAt.toIso8601String(),
      });
    },
  );

  test('no served tool arms, changes or cancels a resume', () {
    // Arming one is a person's act or the setting a person chose. A tool that
    // could would let an agent schedule an agent — the line
    // `no_automation_tools_test.dart` holds for automations.
    final names = [
      for (final schema in LauncherControlServer.toolSchemas)
        schema['name']! as String,
    ];
    expect(
      names.where(
        (name) => name.contains('resume_on') || name.contains('scheduled'),
      ),
      isEmpty,
    );
  });

  test('a paired phone reads it in the session card\'s own clause', () {
    final presence = h.container.read(remoteSessionPresenceProvider);
    expect(presence('s1').note ?? '', isNot(contains('resumes')));

    final resume = h.controller.schedule(inTwoHours());
    expect(
      presence('s1').note,
      startsWith('resumes ${formatResetClock(resume.fireAt, h.now.toLocal())}'),
    );
  });

  test('and arming or cancelling one moves that session\'s row, which is what '
      'the phone\'s list is swept on', () {
    final before = h.container.read(sessionsRevisionProvider);
    h.controller.schedule(inTwoHours());
    final armed = h.container.read(sessionsRevisionProvider);
    expect(armed, isNot(before));
    h.controller.cancelFor('s1');
    expect(h.container.read(sessionsRevisionProvider), isNot(armed));
  });
}
