import 'package:karmashala/src/app/theme/design_tokens.dart';
import 'package:karmashala/src/features/browser/application/browser_pane_controller.dart';
import 'package:karmashala/src/features/browser/application/browser_providers.dart';
import 'package:karmashala/src/features/browser/presentation/browser_pane.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_browser.dart';

/// Records what the pane sends, instead of launching an agent.
class RecordingSessionActions extends SessionActions {
  RecordingSessionActions(super.ref);

  final List<(String, String)> sent = [];

  @override
  Future<void> continueSession(String sessionId, String text) async =>
      sent.add((sessionId, text));
}

/// The picker payload the page reports when the user clicks an element.
const String _pickPayload =
    '{"ok":true,"selector":"#hero","tagName":"section","id":"hero",'
    '"classNames":["banner"],"box":{"x":0,"y":0,"width":320,"height":180},'
    '"url":"https://example.com/app","title":"Example"}';

class Harness {
  Harness({List<String> targets = const ['PAGE-1']})
    : fake = FakeBrowser(
        targets: [for (final id in targets) fakeTarget(id, title: 'Tab $id')],
      ) {
    fake.onEvaluate = (expression) {
      if (expression.contains('__karmashalaPicker')) return true;
      if (expression == 'location.href') return 'https://example.com/app';
      if (expression == 'document.title') return 'Example';
      return null;
    };
  }

  final FakeBrowser fake;
  RecordingSessionActions? actions;

  Future<void> pump(WidgetTester tester, {String? sessionId}) async {
    tester.view
      ..physicalSize = const Size(900, 1100)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          browserServiceProvider.overrideWithValue(fake.service),
          sessionActionsProvider.overrideWith((ref) {
            actions = RecordingSessionActions(ref);
            return actions!;
          }),
          if (sessionId != null)
            selectedSessionIdProvider.overrideWith(
              () => _SelectedSession(sessionId),
            ),
        ],
        child: const MaterialApp(home: Scaffold(body: BrowserPane())),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Attaches and then picks an element, as the developer would.
  Future<void> attachAndPick(WidgetTester tester) async {
    await tester.tap(find.text('Attach · 9222'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick element'));
    await tester.pump();
    await tester.pump();
    expect(
      fake.expressions.any((e) => e.contains('__karmashalaPicker')),
      isTrue,
      reason: 'the pane must have installed the picker before a click counts',
    );
    fake.socket.emitEvent('Runtime.bindingCalled', {
      'name': '__karmashalaPick',
      'payload': _pickPayload,
    });
    await tester.pumpAndSettle();
  }
}

class _SelectedSession extends SelectedSessionController {
  _SelectedSession(this._id);
  final String _id;

  @override
  String? build() => _id;
}

void main() {
  testWidgets('says it is not connected, and how attaching works', (
    tester,
  ) async {
    await Harness().pump(tester);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Attach · 9222'), findsOneWidget);
    expect(find.textContaining('--remote-debugging-port=9222'), findsOneWidget);
    expect(find.textContaining('throwaway profile'), findsOneWidget);
  });

  testWidgets('attaching reports which browser, verbatim', (tester) async {
    final harness = Harness();
    await harness.pump(tester);
    await tester.tap(find.text('Attach · 9222'));
    await tester.pumpAndSettle();
    expect(
      find.text('Attached to the browser already listening on port 9222'),
      findsOneWidget,
    );
    expect(find.text('Detach'), findsOneWidget);
    expect(harness.fake.service.isConnected, isTrue);
  });

  testWidgets('a failure shows the browser\'s own message, not "went wrong"', (
    tester,
  ) async {
    final harness = Harness(targets: const []);
    await harness.pump(tester);
    await tester.tap(find.text('Attach · 9222'));
    await tester.pumpAndSettle();
    expect(find.textContaining('has no page to drive'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('the address bar navigates the attached page', (tester) async {
    final harness = Harness();
    await harness.pump(tester);
    await tester.tap(find.text('Attach · 9222'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'localhost:3000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final navigations = harness.fake.framesFor('Page.navigate');
    expect(navigations.single['url'], 'http://localhost:3000');
  });

  testWidgets('picking shows the element, its selector and a preview', (
    tester,
  ) async {
    final harness = Harness();
    await harness.pump(tester);
    await harness.attachAndPick(tester);
    expect(find.text('section#hero.banner'), findsOneWidget);
    expect(find.text('#hero'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('WHAT WILL BE SENT'), findsOneWidget);
  });

  testWidgets('without a session, sending is disabled and says why', (
    tester,
  ) async {
    final harness = Harness();
    await harness.pump(tester);
    await harness.attachAndPick(tester);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send to session'),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('Open a session'), findsOneWidget);
  });

  testWidgets('sends the whole bundle to the open session', (tester) async {
    final harness = Harness();
    await harness.pump(tester, sessionId: 'S-1');
    await harness.attachAndPick(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Send to session'));
    await tester.pumpAndSettle();
    final sent = harness.actions!.sent.single;
    expect(sent.$1, 'S-1');
    expect(sent.$2, contains('### section#hero.banner'));
    expect(sent.$2, contains('Selector: `#hero`'));
    expect(sent.$2, contains('```html'));
    expect(sent.$2, contains('Screenshot file:'));
    expect(find.text('Sent to the open session.'), findsOneWidget);
  });

  testWidgets('every drivable tab is offered, with the driven one selected', (
    tester,
  ) async {
    final harness = Harness(targets: const ['PAGE-1', 'PAGE-2']);
    await harness.pump(tester);
    await tester.tap(find.text('Attach · 9222'));
    await tester.pumpAndSettle();
    final picker = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(picker.value, 'PAGE-1');
    expect(picker.items!.map((item) => item.value), ['PAGE-1', 'PAGE-2']);
    expect(picker.onChanged, isNotNull);
  });

  testWidgets('the tab picker is sized like the pane around it', (
    tester,
  ) async {
    // `DropdownButton` is Material 2 and ignores the app's
    // `dropdownMenuTheme`, which only reaches Material 3's `DropdownMenu`. Left
    // alone it drew Material's ~16px `titleMedium` with a 24px chevron, in a
    // pane whose status line, address bar and buttons are all `bodySmall` and
    // `Chrome.icon`. The tab title carried a literal `fontSize: 12` to
    // compensate, which fixed the open list and left the closed button and its
    // chevron oversized.
    final harness = Harness(targets: const ['PAGE-1', 'PAGE-2']);
    await harness.pump(tester);
    await tester.tap(find.text('Attach · 9222'));
    await tester.pumpAndSettle();
    final finder = find.byType(DropdownButton<String>);
    final picker = tester.widget<DropdownButton<String>>(finder);
    final theme = Theme.of(tester.element(finder));
    expect(picker.style, theme.textTheme.bodySmall);
    expect(picker.iconSize, Chrome.icon);
    expect(picker.isDense, isTrue);
    // Nothing under it re-decides the size for itself.
    for (final item in picker.items!) {
      expect((item.child as Text).style, isNull);
    }
  });

  testWidgets('the address bar is the same box as every other text field', (
    tester,
  ) async {
    // It used to declare `border: OutlineInputBorder()` for itself, which is
    // Material's 4px radius and default stroke — a visibly different box from
    // the `Radii.sm` / `outlineVariant` one the theme draws for the logs
    // panel's filter field a tab away.
    final harness = Harness();
    await harness.pump(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration!.border, isNull);
    expect(field.decoration!.contentPadding, isNull);
    expect(field.decoration!.isDense, isNull);
    expect(field.style, MonoStyles.body);
  });

  testWidgets('a single tab does not get a picker', (tester) async {
    final harness = Harness();
    await harness.pump(tester);
    await tester.tap(find.text('Attach · 9222'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButton<String>), findsNothing);
  });

  group('the controller', () {
    test('adds a scheme so localhost:3000 is not read as one', () async {
      final fake = FakeBrowser();
      final container = ProviderContainer(
        overrides: [browserServiceProvider.overrideWithValue(fake.service)],
      );
      addTearDown(container.dispose);
      final controller = container.read(browserPaneControllerProvider.notifier);
      await controller.navigate('localhost:3000');
      expect(
        fake.framesFor('Page.navigate').single['url'],
        'http://localhost:3000',
      );
      expect(
        container.read(browserPaneControllerProvider).status,
        BrowserPaneStatus.connected,
      );
    });

    test('leaves a real URL alone', () async {
      final fake = FakeBrowser();
      final container = ProviderContainer(
        overrides: [browserServiceProvider.overrideWithValue(fake.service)],
      );
      addTearDown(container.dispose);
      await container
          .read(browserPaneControllerProvider.notifier)
          .navigate('https://example.com/x?y=1');
      expect(
        fake.framesFor('Page.navigate').single['url'],
        'https://example.com/x?y=1',
      );
    });

    test(
      'switching tabs drives the other page, and reports no false failure',
      () async {
        final fake = FakeBrowser(
          targets: [fakeTarget('PAGE-1'), fakeTarget('PAGE-2')],
        );
        final container = ProviderContainer(
          overrides: [browserServiceProvider.overrideWithValue(fake.service)],
        );
        addTearDown(container.dispose);
        final controller = container.read(
          browserPaneControllerProvider.notifier,
        );
        await controller.connect();
        await controller.selectTab('PAGE-2');
        expect(fake.service.session!.page.target.id, 'PAGE-2');
        final state = container.read(browserPaneControllerProvider);
        expect(state.currentTargetId, 'PAGE-2');
        expect(state.status, BrowserPaneStatus.connected);
        expect(
          state.error,
          isNull,
          reason: 'tearing down our own session is not a disconnection',
        );
      },
    );

    test(
      'a browser that goes away stops being reported as connected',
      () async {
        final fake = FakeBrowser();
        final container = ProviderContainer(
          overrides: [browserServiceProvider.overrideWithValue(fake.service)],
        );
        addTearDown(container.dispose);
        final controller = container.read(
          browserPaneControllerProvider.notifier,
        );
        await controller.connect();
        expect(
          container.read(browserPaneControllerProvider).isConnected,
          isTrue,
        );
        fake.socket.drop();
        await Future<void>.delayed(Duration.zero);
        final state = container.read(browserPaneControllerProvider);
        expect(state.status, BrowserPaneStatus.disconnected);
        expect(state.error, contains('The browser disconnected'));
      },
    );
  });
}
