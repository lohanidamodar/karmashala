import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/message_composer.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

/// **A box opened to be typed in takes the keys**, on a pointer. On a phone
/// that would raise the keyboard over the chat, so it does not.
void main() {
  Future<void> pumpBox(
    WidgetTester tester, {
    required bool Function() takes,
    UiDensity density = UiDensity.pointer,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: density.themeFor(AppTheme.dark()),
          builder: (_, child) =>
              UiDensityScope(density: density, child: child!),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MessageComposer(
                takesKeysOnOpen: takes,
                hintText: 'Message the agent…',
                onSend: (_) async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  bool typing() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  testWidgets('it takes the keys when asked', (tester) async {
    await pumpBox(tester, takes: () => true);
    expect(typing(), isTrue);
  });

  testWidgets('it leaves them when not', (tester) async {
    await pumpBox(tester, takes: () => false);
    expect(typing(), isFalse);
  });

  testWidgets('at touch density it leaves them, and the ask is spent', (
    tester,
  ) async {
    var asked = 0;
    await pumpBox(
      tester,
      takes: () {
        asked++;
        return true;
      },
      density: UiDensity.touch,
    );
    expect(typing(), isFalse);
    expect(asked, 1);
  });

  test('an ask is for its session, and is taken once', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final asks = container.read(composerKeysAskProvider.notifier);
    asks.ask('a');
    expect(asks.take('b'), isFalse);
    expect(asks.take('a'), isTrue);
    expect(asks.take('a'), isFalse);
  });
}
