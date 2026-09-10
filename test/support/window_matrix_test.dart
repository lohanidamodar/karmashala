import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';

import 'window_matrix.dart';

/// The matrix guards other tests, so it needs a guard of its own: a green run
/// against a broken surface would make every surface it covers look fine.
///
/// Each test here pumps something known to be wrong and asserts the matrix says
/// so, then pumps the fixed version and asserts it goes quiet.

Widget wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child), debugShowCheckedModeBanner: false);

void main() {
  testWidgets('it catches a column that does not fit the minimum window', (
    tester,
  ) async {
    await expectLater(
      () => expectSurvivesWindowMatrix(
        tester,
        build: () => wrap(
          Column(
            children: [
              // Width matters: RenderFlex.paint returns before reporting when
              // its own size is empty, so a zero-width column overflows in
              // silence. That is a real way to miss a finding.
              for (var i = 0; i < 8; i++)
                const SizedBox(height: 100, width: 200),
            ],
          ),
        ),
        checkFocus: false,
        checkSemantics: false,
      ),
      throwsA(
        isA<TestFailure>().having(
          (f) => f.message,
          'message',
          allOf(
            contains('720x560 (minimum window)'),
            contains('overflow'),
            contains('on the bottom'),
            // 800 of content in 560 of window.
            contains('240'),
            // The same column fits an ordinary desktop window.
            isNot(contains('1440x900')),
          ),
        ),
      ),
    );
  });

  testWidgets('it catches text scaling that only breaks at 1.3x', (
    tester,
  ) async {
    // Fits at 1.0 in both windows; the fixed height is what fails when the text
    // grows. This is the failure mode a plain 720x560 test misses.
    await expectLater(
      () => expectSurvivesWindowMatrix(
        tester,
        build: () => wrap(
          const SizedBox(
            width: 300,
            height: 44,
            child: Column(children: [Text('first line'), Text('second line')]),
          ),
        ),
        checkFocus: false,
        checkSemantics: false,
      ),
      throwsA(
        isA<TestFailure>().having(
          (f) => f.message,
          'message',
          allOf(contains('@ 1.3x text'), contains('overflow')),
        ),
      ),
    );
  });

  testWidgets('it catches an icon-only button with no accessible name', (
    tester,
  ) async {
    await expectLater(
      () => expectSurvivesWindowMatrix(
        tester,
        build: () =>
            wrap(IconButton(onPressed: () {}, icon: const Icon(Icons.close))),
        checkFocus: false,
      ),
      throwsA(
        isA<TestFailure>().having(
          (f) => f.message,
          'message',
          allOf(
            contains('semantics'),
            contains('no accessible name'),
            contains('Narrator'),
          ),
        ),
      ),
    );
  });

  testWidgets('a tooltip is an accessible name', (tester) async {
    await expectSurvivesWindowMatrix(
      tester,
      build: () => wrap(
        IconButton(
          tooltip: 'Close',
          onPressed: () {},
          icon: const Icon(Icons.close),
        ),
      ),
    );
  });

  testWidgets('a list long enough to recycle its rows still closes its ring', (
    tester,
  ) async {
    // Thirty rows in a 560-tall window is more than the sliver keeps: by the
    // time Tab reaches the last one the first row has been disposed, so the
    // node the harness recorded as "the first stop" no longer exists and the
    // traversal wraps to the earliest row that does. Identity called that a
    // revisit — a focus trap — against a list that has none, and every long
    // scrolling surface in the app was covered by that check.
    //
    // [RevealOnFocus] is what keeps the wrapped-to rows on screen; without it
    // the same run reports five stops above the window edge, because forward
    // traversal's `keepVisibleAtEnd` will not scroll backwards.
    await expectSurvivesWindowMatrix(
      tester,
      build: () => wrap(
        ListView.builder(
          itemCount: 30,
          itemBuilder: (context, index) => RevealOnFocus(
            child: ListTile(title: Text('Row $index'), onTap: () {}),
          ),
        ),
      ),
      checkSemantics: false,
      because: 'a lazy list disposes the row the ring started at',
    );
  });

  testWidgets('a well-behaved surface produces nothing', (tester) async {
    await expectSurvivesWindowMatrix(
      tester,
      build: () => wrap(
        Column(
          children: [
            const Text('Title'),
            TextButton(onPressed: () {}, child: const Text('One')),
            TextButton(onPressed: () {}, child: const Text('Two')),
          ],
        ),
      ),
    );
  });
}
