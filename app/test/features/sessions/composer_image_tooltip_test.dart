import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_prompt_kinds_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/message_composer.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

/// A 1x1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

/// **The attachment's tooltip says how an image reaches the agent**: as an
/// image when the session's agent takes them, as a file path when not.
void main() {
  Future<void> pasteImage(
    WidgetTester tester, {
    required bool Function()? asImages,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              MessageComposer(
                hintText: 'Message',
                imagesGoAsImages: asImages,
                onSend: (_) async {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(
        find.byTooltip('Attach a file (paste an image with Ctrl+V)'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  testWidgets('an agent that takes images is sent it as an image', (
    tester,
  ) async {
    await pasteImage(tester, asImages: () => true);
    expect(
      find.byTooltip(
        'Saved to a temp folder and sent to the agent as an image.',
      ),
      findsOneWidget,
    );
  });

  for (final (name, asImages) in [
    ('one that takes none', () => false),
    ('a host that says nothing', null),
  ]) {
    testWidgets('$name is given its path', (tester) async {
      await pasteImage(tester, asImages: asImages);
      expect(
        find.byTooltip(
          'Saved to a temp folder and sent to the agent as a file path.',
        ),
        findsOneWidget,
      );
    });
  }

  test(
    "the provider follows what the server tells of a session's agent",
    () async {
      final machine = TestMachine();
      final server = FakeDataServer()..runsOn(machine);
      final container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);
      final read = container.listen(
        sessionTakesImagesProvider('s1'),
        (_, _) {},
      );
      expect(read.read(), isFalse);

      server.writeAsAnotherClient([
        const SessionPromptKindsChanged(sessionId: 's1', images: true),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(read.read(), isTrue);
    },
  );
}
