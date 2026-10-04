import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_input.dart';
import 'package:karmashala/src/features/sessions/application/session_subagents_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/stop_children_offer.dart';

class _FakeInput implements SessionInput {
  final interrupted = <String>[];

  @override
  bool get viaServer => true;

  @override
  Future<bool> interrupt(String sessionId) async {
    interrupted.add(sessionId);
    return true;
  }

  @override
  Future<bool> send(String sessionId, String text, {String? requestId}) =>
      throw UnimplementedError();
}

/// Stopping a parent offers, once, to stop the child sessions still working
/// under it; it never stops them unasked.
void main() {
  Future<_FakeInput> pump(WidgetTester tester, List<String> running) async {
    final input = _FakeInput();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          runningChildSessionsProvider('parent').overrideWithValue(running),
          sessionInputProvider.overrideWithValue(input),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => offerToStopChildren(context, ref, 'parent'),
                child: const Text('Stop'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Stop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
    return input;
  }

  testWidgets('offers to stop the children still working, and stops them '
      'only when asked', (tester) async {
    final input = await pump(tester, const ['c1', 'c2']);
    expect(find.textContaining('2 child sessions are still working'), findsOne);
    expect(input.interrupted, isEmpty);

    await tester.tap(find.text('Stop them too'));
    await tester.pump();
    expect(input.interrupted, ['c1', 'c2']);
  });

  testWidgets('says nothing when no child is working', (tester) async {
    final input = await pump(tester, const []);
    expect(find.byType(SnackBar), findsNothing);
    expect(input.interrupted, isEmpty);
  });
}
