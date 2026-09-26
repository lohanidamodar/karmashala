import 'package:agent_cli/process.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/diff_tab_actions.dart';
import 'package:karmashala/src/features/git/presentation/diff_line_tile.dart';
import 'package:karmashala/src/features/git/presentation/diff_tab_view.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'review_thread_harness.dart';

const _target = DiffTarget(
  checkout: EnvironmentPath(environmentId: 'env-win', path: r'C:\src\app'),
  path: 'lib/a.dart',
);

/// One line far wider than any pane, so the diff has to scroll sideways.
final _diff =
    '@@ -1,3 +1,3 @@\n final a = 1;\n-final b = 2;\n'
    '+final b = ${'3 + ' * 60}3;\n final c = 4;\n';

/// A diff tab is often a narrow split: its comment action has to stay on
/// screen however wide the code is.
void main() {
  late ReviewThreadHarness harness;

  setUp(
    () async => harness = await ReviewThreadHarness.create(
      shas: {'lib/a.dart': 'sha-one'},
    ),
  );
  tearDown(() => harness.dispose());

  Widget tab(double width, {Key? key}) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(harness.db),
      dataClientProvider.overrideWithValue(harness.client),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('t-')),
      changesServiceProvider.overrideWithValue(
        harness.container.read(changesServiceProvider),
      ),
      diffForTargetProvider(_target).overrideWith((ref) async => _diff),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 400,
            child: StatefulBuilder(
              key: key,
              builder: (context, setState) => DiffTabView(target: _target),
            ),
          ),
        ),
      ),
    ),
  );

  for (final width in [200.0, 280.0, 480.0]) {
    testWidgets('the comment action is inside a ${width}px pane', (
      tester,
    ) async {
      await tester.pumpWidget(tab(width));
      await tester.pumpAndSettle();

      final buttons = find.byTooltip('Add review comment');
      expect(buttons, findsWidgets);
      for (final rect in [
        for (final element in buttons.evaluate())
          tester.getRect(find.byWidget(element.widget)),
      ]) {
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(width));
      }
      expect(buttons.hitTestable(), findsWidgets);
    });
  }

  testWidgets('the diff is parsed once, not on every rebuild', (tester) async {
    final key = GlobalKey<State<StatefulWidget>>();
    await tester.pumpWidget(tab(480, key: key));
    await tester.pumpAndSettle();

    DiffLineTile firstRow() =>
        tester.widget<DiffLineTile>(find.byType(DiffLineTile).first);
    final parsed = firstRow().line;

    for (var i = 0; i < 3; i++) {
      // ignore: invalid_use_of_protected_member
      key.currentState!.setState(() {});
      await tester.pump();
    }

    expect(identical(firstRow().line, parsed), isTrue);
  });

  testWidgets('a sideways wheel scrolls the code and not the comment column', (
    tester,
  ) async {
    await tester.pumpWidget(tab(280));
    await tester.pumpAndSettle();

    final longLine = find.textContaining('+final b = 3 + ');
    final comment = find.byTooltip('Add review comment').at(1);
    final textBefore = tester.getTopLeft(longLine);
    final commentBefore = tester.getTopLeft(comment);

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(textBefore + const Offset(40, 6)),
    );
    await tester.sendEventToBinding(pointer.scroll(const Offset(100, 0)));
    await tester.pump();

    expect(tester.getTopLeft(longLine).dx, textBefore.dx - 100);
    expect(tester.getTopLeft(comment), commentBefore);
    // One bar for each direction, the vertical one on the list itself.
    expect(find.byType(Scrollbar), findsNWidgets(2));
  });
}
