import 'package:flutter_test/flutter_test.dart';

/// Lets the chat's picture reads finish: they are real file and server I/O,
/// which completes only outside the test's fake clock.
Future<void> settleImageReads(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
}
