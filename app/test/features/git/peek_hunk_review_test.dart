import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/git/presentation/diff_view.dart';
import 'package:karmashala/src/features/sessions/presentation/hunk_review.dart';
import 'package:karmashala_git/repositories.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'review_thread_harness.dart';

/// The peek's Files tab: a checkout's diff against git, with Keep and Revert
/// on each hunk where the session's review is in scope, and none elsewhere.
void main() {
  const checkout = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\demo\app',
  );
  const diff =
      '@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n'
      '@@ -40,3 +40,3 @@\n x\n-y\n+Y\n z\n';

  Future<void> pump(
    WidgetTester tester,
    ReviewThreadHarness harness, {
    HunkReview? review,
  }) async {
    harness.server.gitWork.diffs[(Checkout(checkout), 'lib/a.dart', false)] =
        diff;
    Widget view = const FileDiffView(
      path: 'lib/a.dart',
      checkout: checkout,
      repositoryId: 'r1',
      reviewHunks: true,
    );
    if (review != null) {
      view = HunkReviewScope(review: review, revision: 0, child: view);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dataClientProvider.overrideWithValue(harness.client),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(
            SequentialIdGenerator('peek-hunk-'),
          ),
        ],
        child: MaterialApp(home: Scaffold(body: view)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('each hunk of the git diff gets Keep and Revert', (tester) async {
    final harness = await ReviewThreadHarness.create(
      shas: {'lib/a.dart': 'sha-one'},
    );
    addTearDown(harness.dispose);
    final review = _RecordingReview();
    await pump(tester, harness, review: review);

    expect(find.byKey(const ValueKey('hunk-bar-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('hunk-bar-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hunk-revert')).last);
    await tester.tap(find.byKey(const ValueKey('hunk-keep')).first);
    await tester.pump();
    expect(review.calls, ['revert lib/a.dart 1', 'keep 0']);
    expect(review.lastHunk!.after, ['x', 'Y', 'z']);
    expect(review.lastHunk!.newStart, 40);
  });

  testWidgets('without a review in scope, a diff offers neither', (
    tester,
  ) async {
    final harness = await ReviewThreadHarness.create(
      shas: {'lib/a.dart': 'sha-one'},
    );
    addTearDown(harness.dispose);
    await pump(tester, harness);
    expect(find.byKey(const ValueKey('hunk-revert')), findsNothing);
  });

  test('a git path is spelled for its checkout', () {
    expect(
      checkoutFile(checkout, 'lib/a.dart').path,
      r'C:\src\demo\app\lib\a.dart',
    );
    expect(
      checkoutFile(
        const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/home/me/app',
        ),
        'lib/a.dart',
      ).path,
      '/home/me/app/lib/a.dart',
    );
  });
}

class _RecordingReview implements HunkReview {
  final calls = <String>[];
  EditHunk? lastHunk;

  @override
  bool kept(EditHunk hunk) => false;

  @override
  bool reverted(EditHunk hunk) => false;

  @override
  void toggleKept(EditHunk hunk) => calls.add('keep ${hunk.index}');

  @override
  Future<void> revertHunk(BuildContext context, EditHunk hunk) async {
    lastHunk = hunk;
    calls.add('revert ${hunk.path} ${hunk.index}');
  }

  @override
  Future<void> revertFile(
    BuildContext context,
    String path,
    List<EditHunk> hunks,
  ) async => calls.add('revert file $path');
}
