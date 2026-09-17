import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_notice.dart';
import 'package:karmashala/src/features/sessions/presentation/session_notice_line.dart';

/// Two sessions' bars side by side, which is the arrangement the whole feature
/// is about: the workbench has one open pane's bar on screen while other
/// sessions run behind it, and a message meant for one of them must not appear
/// under the other.
Widget _twoBars() => const ProviderScope(
  child: MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          SessionNoticeLine(sessionId: 'a'),
          SessionNoticeLine(sessionId: 'b'),
        ],
      ),
    ),
  ),
);

SessionNotices _notices(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(SessionNoticeLine).first),
).read(sessionNoticesProvider.notifier);

void main() {
  testWidgets('a notice is drawn only in the session it is about', (
    tester,
  ) async {
    await tester.pumpWidget(_twoBars());
    _notices(tester).post('a', const SessionNotice(message: 'Bypass mode'));
    await tester.pump();

    expect(find.text('Bypass mode'), findsOneWidget);
    // The one that matters: session b is open at the same time and says
    // nothing. A snackbar could not make this distinction — it is one strip
    // across the window, so every session's message landed on all of them.
    expect(
      find.descendant(
        of: find.byWidget(
          tester
              .widgetList<SessionNoticeLine>(find.byType(SessionNoticeLine))
              .last,
        ),
        matching: find.text('Bypass mode'),
      ),
      findsNothing,
    );
  });

  testWidgets('nothing is laid out while there is nothing to say', (
    tester,
  ) async {
    await tester.pumpWidget(_twoBars());
    // Not merely invisible: an empty bar holding its height would push the
    // composer down and pull it back every time a chip was used.
    expect(tester.getSize(find.byType(SessionNoticeLine).first), Size.zero);
  });

  testWidgets('the newest notice replaces the one before it', (tester) async {
    await tester.pumpWidget(_twoBars());
    final notices = _notices(tester);
    notices.post('a', const SessionNotice(message: 'Plan mode'));
    await tester.pump();
    notices.post('a', const SessionNotice(message: 'Bypass mode'));
    await tester.pump();

    // These messages describe what the session is now, so two of them on
    // screen would be one true line and one stale one, with nothing saying
    // which.
    expect(find.text('Plan mode'), findsNothing);
    expect(find.text('Bypass mode'), findsOneWidget);
  });

  testWidgets('the user can take it down before it goes', (tester) async {
    await tester.pumpWidget(_twoBars());
    _notices(tester).post('a', const SessionNotice(message: 'Bypass mode'));
    await tester.pump();

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.text('Bypass mode'), findsNothing);
  });

  testWidgets('it clears itself once it has been up long enough', (
    tester,
  ) async {
    await tester.pumpWidget(_twoBars());
    _notices(tester).post('a', const SessionNotice(message: 'Bypass mode'));
    await tester.pump();

    await tester.pump(sessionNoticeLifetime - const Duration(seconds: 1));
    expect(
      find.text('Bypass mode'),
      findsOneWidget,
      reason: 'still readable a moment before its time is up',
    );

    await tester.pump(const Duration(seconds: 2));
    // Otherwise "applies the next time this session is launched" would still
    // be sitting in the bar after the launch it was talking about.
    expect(find.text('Bypass mode'), findsNothing);
  });

  testWidgets('a bar that goes away takes its clock with it', (tester) async {
    await tester.pumpWidget(_twoBars());
    _notices(tester).post('a', const SessionNotice(message: 'Bypass mode'));
    await tester.pump();

    // Closing the pane the notice was drawn in. The test framework fails the
    // test on a pending timer, which is the assertion: an expiry counted in
    // the provider rather than here would outlive every bar that ever drew it
    // and fire against a disposed tree.
    await tester.pumpWidget(const ProviderScope(child: MaterialApp()));
  });

  testWidgets('taking the offer runs it once and retires it', (tester) async {
    await tester.pumpWidget(_twoBars());
    var restarts = 0;
    _notices(tester).post(
      'a',
      SessionNotice(
        message: 'Bypass mode',
        action: SessionNoticeAction(
          label: 'Restart to apply',
          onPressed: () => restarts++,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Restart to apply'));
    await tester.pump();

    expect(restarts, 1);
    // The offer goes with it. A "Restart to apply" button still sitting there
    // after the restart invites a second one, which would end the process the
    // first one just started.
    expect(find.text('Restart to apply'), findsNothing);
  });

  testWidgets('a second action is drawn after the first, and either retires '
      'the notice', (tester) async {
    await tester.pumpWidget(_twoBars());
    final taken = <String>[];
    _notices(tester).post(
      'a',
      SessionNotice(
        message: 'Codex hit its 5-hour limit. Resets 14:05.',
        action: SessionNoticeAction(
          label: 'Resume then',
          onPressed: () => taken.add('resume'),
        ),
        secondaryAction: SessionNoticeAction(
          label: 'Options…',
          onPressed: () => taken.add('options'),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getTopLeft(find.text('Resume then')).dx,
      lessThan(tester.getTopLeft(find.text('Options…')).dx),
    );
    await tester.tap(find.text('Options…'));
    await tester.pump();
    expect(taken, ['options']);
    expect(find.text('Resume then'), findsNothing);
  });

  testWidgets('a sticky notice outlasts the clock, and is still dismissable', (
    tester,
  ) async {
    await tester.pumpWidget(_twoBars());
    _notices(tester).post(
      'a',
      const SessionNotice(message: 'Limit reached', sticky: true),
    );
    await tester.pump();
    await tester.pump(sessionNoticeLifetime * 3);
    expect(find.text('Limit reached'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.text('Limit reached'), findsNothing);
  });

  testWidgets('two actions fit a side panel\'s width without overflowing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(240, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_twoBars());
    _notices(tester).post(
      'a',
      SessionNotice(
        message: 'Codex hit its 5-hour limit. Resets 14:05.',
        sticky: true,
        action: SessionNoticeAction(label: 'Resume then', onPressed: () {}),
        secondaryAction: SessionNoticeAction(
          label: 'Options…',
          onPressed: () {},
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Under the sentence, not squeezed beside it.
    expect(
      tester.getTopLeft(find.text('Resume then')).dy,
      greaterThan(tester.getTopLeft(find.textContaining('Codex hit')).dy),
    );
  });
}
