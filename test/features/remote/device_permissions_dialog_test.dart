/// Editing a paired phone's permissions: the chips start at what it holds,
/// Save answers with the new grant, and a grant made by a newer build is
/// carried through untouched rather than dropped by a dialog that cannot draw
/// it. Nothing here starts a service or opens a socket.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/presentation/capability_labels.dart';
import 'package:karmashala/src/features/remote/presentation/device_permissions_dialog.dart';
import 'package:karmashala_remote/remote.dart';

/// What the dialog answered with, once it has closed.
class _Answer {
  CapabilitySet? granted;
  bool closed = false;
}

void main() {
  Future<_Answer> open(WidgetTester tester, CapabilitySet granted) async {
    final answer = _Answer();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answer.granted = await DevicePermissionsDialog.show(
                context,
                'Oppo',
                granted,
              );
              answer.closed = true;
            },
            child: const Text('Permissions'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Permissions'));
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('the chips start at what the device holds', (tester) async {
    final answer = await open(
      tester,
      CapabilitySet.of(const [Capability.viewSessions]),
    );

    FilterChip chipFor(Capability capability) => tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, capabilityLabel(capability)),
    );
    expect(chipFor(Capability.viewSessions).selected, isTrue);
    expect(chipFor(Capability.sendPrompt).selected, isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(answer.closed, isTrue);
    expect(answer.granted, isNull, reason: 'Cancel changes nothing');
  });

  testWidgets('Save answers with the grant as edited', (tester) async {
    final answer = await open(
      tester,
      CapabilitySet.of(const [Capability.viewSessions]),
    );

    await tester.tap(
      find.widgetWithText(FilterChip, capabilityLabel(Capability.sendPrompt)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final granted = answer.granted;
    expect(granted, isNotNull);
    expect(granted!.has(Capability.viewSessions), isTrue);
    expect(granted.has(Capability.sendPrompt), isTrue);
    expect(granted.has(Capability.approve), isFalse);
  });

  testWidgets('Save is offered only once something moved', (tester) async {
    await open(tester, CapabilitySet.all);

    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  test('a bit this build cannot draw survives an edit', () {
    // Bit 30: granted by a build that knows more than this one.
    final future = CapabilitySet(
      CapabilitySet.of(const [Capability.viewSessions]).bits | (1 << 30),
    );

    final edited = capabilitiesWith(future, const [
      Capability.viewSessions,
      Capability.approve,
    ]);

    expect(edited.bits & (1 << 30), 1 << 30);
    expect(edited.has(Capability.approve), isTrue);
    expect(edited.has(Capability.sendPrompt), isFalse);
  });
}
