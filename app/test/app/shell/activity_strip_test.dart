import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/activity_strip.dart';
import 'package:karmashala/src/app/shell/shell_area.dart';
import 'package:karmashala_ui/theme.dart';

/// The activity strip (UI overhaul spec §4), drawn from values.
void main() {
  Future<List<Object>> pump(
    WidgetTester tester, {
    ShellArea? selected = ShellArea.projects,
    Map<ShellArea, int> badges = const {},
  }) async {
    final events = <Object>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              height: 600,
              child: ActivityStrip(
                selected: selected,
                badges: badges,
                onSelect: events.add,
                onSettings: () => events.add('settings'),
              ),
            ),
          ),
        ),
      ),
    );
    return events;
  }

  testWidgets('one button per area and Settings, each named', (tester) async {
    await pump(tester);
    for (final area in ShellArea.values) {
      expect(find.bySemanticsLabel(area.label), findsOneWidget);
    }
    expect(find.bySemanticsLabel('Settings'), findsOneWidget);
  });

  testWidgets('pressing an area or Settings says so', (tester) async {
    final events = await pump(tester);
    await tester.tap(find.bySemanticsLabel('Terminals'));
    await tester.tap(find.bySemanticsLabel('Settings'));
    expect(events, [ShellArea.terminals, 'settings']);
  });

  testWidgets('a badge counts what needs the user, and the label says it', (
    tester,
  ) async {
    await pump(tester, badges: {ShellArea.sessions: 2});
    expect(find.text('2'), findsOneWidget);
    expect(find.bySemanticsLabel('Sessions, 2 need you'), findsOneWidget);
  });

  testWidgets('the Devices badge counts devices, not asks', (tester) async {
    await pump(tester, badges: {ShellArea.devices: 1});
    expect(find.bySemanticsLabel('Devices, 1 connected'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('need you')), findsNothing);
  });

  testWidgets('only the showing area is selected; none when hidden', (
    tester,
  ) async {
    await pump(tester, selected: ShellArea.inbox);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Inbox')),
      matchesSemantics(
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        label: 'Inbox',
        tooltip: 'Inbox',
      ),
    );
    await pump(tester, selected: null);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Inbox')),
      matchesSemantics(
        isButton: true,
        hasSelectedState: true,
        label: 'Inbox',
        tooltip: 'Inbox',
      ),
    );
  });
}
