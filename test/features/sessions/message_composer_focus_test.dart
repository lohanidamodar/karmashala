import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/message_composer.dart';
import 'package:karmashala_ui/theme.dart';

/// A 1x1 transparent PNG: a real image, so the thumbnail decodes.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              MessageComposer(hintText: 'Message', onSend: (_) async {}),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('focusing the box redraws its border, not the text field', (
    tester,
  ) async {
    await pump(tester);
    final before = tester.widget<TextField>(find.byType(TextField));

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    expect(
      identical(tester.widget<TextField>(find.byType(TextField)), before),
      isTrue,
      reason: 'a focus change rebuilt the whole composer, text field included',
    );
  });

  testWidgets('the whole drawn remove button takes a tap', (tester) async {
    // The clipboard holds an image, so Attach takes it without a picker.
    final messenger = tester.binding.defaultBinaryMessenger;
    const channel = MethodChannel('pasteboard');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'image') return null;
      if (!Platform.isWindows) return _png;
      final file = File(
        '${Directory.systemTemp.createTempSync('composer').path}/clip.png',
      )..writeAsBytesSync(_png);
      return file.path;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await pump(tester);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Attach image (or paste with Ctrl+V)'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    final remove = find.byTooltip('Remove');
    expect(remove, findsOneWidget);

    // The corner furthest from the thumbnail: outside the Stack it sat in.
    final corner = tester.getRect(remove).topRight + const Offset(-2, 2);
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
    await tester.tapAt(corner);
    await tester.pump();

    expect(remove, findsNothing);
  });
}
