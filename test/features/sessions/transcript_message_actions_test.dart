import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';

/// Copy and Save-as-note confirm for a moment, and a row scrolled away or a
/// session closed mid-confirmation must not leave that moment running.
void main() {
  Widget build(void Function() onSave) => MaterialApp(
    home: Scaffold(
      body: ChatTranscriptView(
        onSaveNote: (_, _) => onSave(),
        messages: const [ChatMessage(role: 'agent', text: 'Done.')],
      ),
    ),
  );

  /// What the fake clipboard was given; the real platform channel never is.
  List<String> fakeClipboard(WidgetTester tester) {
    final copied = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    return copied;
  }

  testWidgets('Copy copies, confirms, then settles back', (tester) async {
    final copied = fakeClipboard(tester);
    await tester.pumpWidget(build(() {}));
    await tester.tap(find.byTooltip('Copy message'));
    await tester.pump();
    expect(copied, ['Done.']);
    expect(find.byTooltip('Copied'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.byTooltip('Copy message'), findsOneWidget);
  });

  testWidgets('Save as note saves once, confirms, then settles back', (
    tester,
  ) async {
    var saves = 0;
    await tester.pumpWidget(build(() => saves++));
    await tester.tap(find.byTooltip('Save as note'));
    await tester.pump();
    expect(saves, 1);
    expect(find.byTooltip('Saved to Notes'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.byTooltip('Save as note'), findsOneWidget);
  });

  testWidgets('a confirmation does not outlive its row', (tester) async {
    fakeClipboard(tester);
    await tester.pumpWidget(build(() {}));
    await tester.tap(find.byTooltip('Copy message'));
    await tester.pump();
    await tester.tap(find.byTooltip('Save as note'));
    await tester.pump();

    // Unmounted mid-confirmation: flutter_test fails the test if a timer is
    // still pending once the tree is gone.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
