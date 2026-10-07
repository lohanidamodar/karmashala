import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_editor_state.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/events.dart' show automationMessage;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../terminal/fake_instance.dart';

/// A message an automation sent into a session reads "Sent by automation
/// Nightly", linked to it, and its first line is not shown as the person's.
void main() {
  const by = AutomationAttribution(automationId: 'auto1', name: 'Nightly [ci]');

  group('the line', () {
    test('renders on one line and splits back, brackets and all', () {
      final text = by.render('The checks failed:\n\nfix them');
      expect(text.split('\n').first, startsWith(by.line));
      final split = AutomationAttribution.split(text)!;
      expect(split.by, by);
      expect(split.rest, 'The checks failed:\n\nfix them');
    });

    test('a person\'s message is nobody\'s automation', () {
      for (final text in [
        'run the tests',
        'see [sent by the Karmashala automation "x" (y)] above',
        '[sent by the Karmashala automation "x"] no id',
      ]) {
        expect(AutomationAttribution.split(text), isNull, reason: text);
      }
    });

    test('an event rule\'s message carries it', () {
      final rule = Automation(
        id: 'r9',
        repositoryId: 'r1',
        name: 'After each turn',
        schedule: AutomationSchedule.once(DateTime.utc(2026)),
        agentInstallationId: '',
        prompt: 'run the tests',
        permissionMode: null,
        enabled: true,
        armedAt: DateTime.utc(2026),
      );
      final split = AutomationAttribution.split(automationMessage(rule))!;
      expect(split.by.automationId, 'r9');
      expect(split.rest, 'run the tests');
    });
  });

  testWidgets('the chat shows the label, not the line, and it opens the '
      'automation, at a phone\'s width and large text', (tester) async {
    final server = FakeDataServer()
      ..environmentRows.upsert(windowsEnv())
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    server.automationRows.insert(
      Automation(
        id: 'auto1',
        repositoryId: 'r1',
        name: 'Nightly [ci]',
        schedule: const AutomationSchedule.cron('0 2 * * *'),
        agentInstallationId: 'a1',
        prompt: 'fix it',
        permissionMode: null,
        enabled: true,
        armedAt: testTime,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
    for (final scale in const [1.0, 1.6]) {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(360, 800),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: ChatTranscriptView(
                  messages: [
                    ChatMessage(
                      role: 'user',
                      text: by.render('The checks failed. Fix them.'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$scale');
      expect(find.byKey(const ValueKey('automation-sent-auto1')), findsOne);
      expect(find.textContaining('[sent by'), findsNothing);
      expect(find.textContaining('The checks failed. Fix them.'), findsOne);
    }

    await tester.tap(find.byKey(const ValueKey('automation-sent-auto1')));
    await tester.pumpAndSettle();
    expect(
      container.read(automationEditorProvider)?.draft.original?.id,
      'auto1',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
