import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/browser/application/browser_pane_controller.dart';
import 'package:karmashala/src/features/browser/presentation/browser_pane.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_browser/browser.dart'
    show ElementBox, ElementCapture;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fake_data_server.dart';

/// Records what the pane sends, instead of launching an agent.
class RecordingSessionActions extends SessionActions {
  RecordingSessionActions(super.ref);

  final List<(String, String)> sent = [];

  @override
  Future<void> continueSession(String sessionId, String text) async =>
      sent.add((sessionId, text));
}

/// One transparent pixel, so the preview has something to draw.
final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
  'hKmMIQAAAABJRU5ErkJggg==',
);

BrowserState attached({
  List<String> tabs = const ['PAGE-1'],
  bool headless = false,
}) => BrowserState(
  status: BrowserStatus.connected,
  connection: 'Attached to the browser already listening on port 9222',
  url: 'https://example.com/app',
  title: 'Example',
  tabs: [
    for (final id in tabs)
      BrowserTab(id: id, title: 'Tab $id', url: 'https://example.com/app'),
  ],
  currentTargetId: tabs.firstOrNull,
  headless: headless,
);

final _pick = BrowserPick(
  ElementCapture(
    selector: '#hero',
    tagName: 'section',
    elementId: 'hero',
    classNames: const ['banner'],
    outerHtml: '<section id="hero" class="banner"></section>',
    computedStyles: const {'display': 'block'},
    box: const ElementBox(x: 0, y: 0, width: 320, height: 180),
    pageUrl: 'https://example.com/app',
    pageTitle: 'Example',
    capturedAt: DateTime.utc(2026, 9, 27),
    screenshotPng: _pixel,
  ),
  captureFile: '/data/captures/element_1.png',
);

/// The server's browser as the pane is a client of it (slice 3d): the pane
/// asks, and what the browser then is arrives as the server's change.
class Harness {
  Harness({BrowserState? whenAttached})
    : _attached = whenAttached ?? attached();

  final server = FakeDataServer();
  final BrowserState _attached;
  RecordingSessionActions? actions;

  Future<void> pump(WidgetTester tester, {String? sessionId}) async {
    server.runs.onBrowser = (request) => switch (request) {
      BrowserConnect() => _attach(),
      BrowserPickElement() => _pick,
      BrowserCancelPick() => const DataAck(),
      _ => server.runs.browser,
    };
    final data = await server.override();
    tester.view
      ..physicalSize = const Size(900, 1100)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          data,
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

  BrowserState _attach() {
    server.runs.setBrowser(_attached);
    return _attached;
  }

  Future<void> attach(WidgetTester tester) async {
    await tester.tap(find.text('Attach · 9222'));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
  }

  Future<void> attachAndPick(WidgetTester tester) async {
    await attach(tester);
    await tester.tap(find.text('Pick element'));
    await tester.runAsync(pumpEventQueue);
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
    // Folded until asked: open, the explanation is taller than a side panel.
    expect(find.textContaining('--remote-debugging-port=9222'), findsNothing);
    await tester.tap(find.text('How attaching works'));
    await tester.pumpAndSettle();
    expect(find.textContaining('--remote-debugging-port=9222'), findsOneWidget);
    expect(find.textContaining('throwaway profile'), findsOneWidget);
    expect(find.textContaining('--user-data-dir'), findsOneWidget);
  });

  testWidgets('attaching asks the server and shows which browser, verbatim', (
    tester,
  ) async {
    final harness = Harness();
    await harness.pump(tester);
    await harness.attach(tester);
    expect(harness.server.runs.asked.whereType<BrowserConnect>(), hasLength(1));
    expect(
      find.text('Attached to the browser already listening on port 9222'),
      findsOneWidget,
    );
    expect(find.text('Detach'), findsOneWidget);
  });

  testWidgets('a browser the server lost is reported in the error banner', (
    tester,
  ) async {
    final harness = Harness();
    await harness.pump(tester);
    await harness.attach(tester);
    harness.server.runs.setBrowser(
      const BrowserState(error: 'The browser disconnected.'),
    );
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();

    expect(find.byType(DesktopErrorBanner), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopErrorBanner), findsNothing);
  });

  testWidgets('a refusal shows the server\'s own words, not "went wrong"', (
    tester,
  ) async {
    final harness = Harness();
    await harness.pump(tester);
    harness.server.runs.onBrowser = (_) => throw const DataRefused(
      DataRefusalCode.failed,
      'Chrome on port 9222 has no page to drive.',
    );
    await harness.attach(tester);
    expect(find.textContaining('has no page to drive'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('the address bar asks the server to go there, as typed', (
    tester,
  ) async {
    final harness = Harness();
    await harness.pump(tester);
    await harness.attach(tester);
    // `.first`: the console under the picture has a field of its own.
    await tester.enterText(find.byType(TextField).first, 'localhost:3000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    // Spelling it as a URL is the server's: one place for the rule.
    final asked = harness.server.runs.asked.whereType<BrowserNavigate>();
    expect(asked.single.url, 'localhost:3000');
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

  testWidgets('sends the whole bundle, the server\'s picture file included', (
    tester,
  ) async {
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
    expect(sent.$2, contains('Screenshot file: /data/captures/element_1.png'));
    expect(find.text('Sent to the open session.'), findsOneWidget);
  });

  testWidgets('a headless server has nothing to pick in, and says so', (
    tester,
  ) async {
    final harness = Harness(whenAttached: attached(headless: true));
    await harness.pump(tester);
    await harness.attach(tester);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Pick element'),
    );
    expect(button.onPressed, isNull);
    expect(find.byTooltip(RegExp('headless')), findsOneWidget);
  });

  testWidgets('every drivable tab is offered, with the driven one selected', (
    tester,
  ) async {
    final harness = Harness(
      whenAttached: attached(tabs: const ['PAGE-1', 'PAGE-2']),
    );
    await harness.pump(tester);
    await harness.attach(tester);
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
    // `DropdownButton` is Material 2 and ignores the app's dropdown theme.
    final harness = Harness(
      whenAttached: attached(tabs: const ['PAGE-1', 'PAGE-2']),
    );
    await harness.pump(tester);
    await harness.attach(tester);
    final finder = find.byType(DropdownButton<String>);
    final picker = tester.widget<DropdownButton<String>>(finder);
    final theme = Theme.of(tester.element(finder));
    expect(picker.style, theme.textTheme.bodySmall);
    expect(picker.iconSize, Chrome.icon);
    expect(picker.isDense, isTrue);
    for (final item in picker.items!) {
      expect((item.child as Text).style, isNull);
    }
  });

  testWidgets('the address bar is the same box as every other text field', (
    tester,
  ) async {
    await Harness().pump(tester);
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.decoration!.border, isNull);
    expect(field.decoration!.contentPadding, isNull);
    expect(field.decoration!.isDense, isNull);
    expect(field.style, MonoStyles.body);
  });

  testWidgets('a single tab does not get a picker', (tester) async {
    final harness = Harness();
    await harness.pump(tester);
    await harness.attach(tester);
    expect(find.byType(DropdownButton<String>), findsNothing);
  });

  group('coming back to Karmashala', () {
    // A landed pick brings the person back; one that landed nothing must not
    // take them off whatever they moved on to.
    Future<(ProviderContainer, FakeDataServer)> attachedPane() async {
      final server = FakeDataServer();
      final container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);
      server.runs.setBrowser(attached());
      await pumpEventQueue();
      return (container, server);
    }

    test('a pick that lands asks for the window, exactly once', () async {
      final (container, server) = await attachedPane();
      server.runs.onBrowser = (_) => _pick;
      await container
          .read(browserPaneControllerProvider.notifier)
          .pickElement();
      expect(container.read(browserPaneControllerProvider).capture, isNotNull);
      expect(container.read(windowRaiseRequestProvider), 1);
    });

    test('a pick the server refused leaves the window where it was', () async {
      final (container, server) = await attachedPane();
      server.runs.onBrowser = (_) => throw const DataRefused(
        DataRefusalCode.failed,
        'The pick was cancelled.',
      );
      await container
          .read(browserPaneControllerProvider.notifier)
          .pickElement();
      expect(
        container.read(browserPaneControllerProvider).error,
        contains('cancelled'),
      );
      expect(container.read(windowRaiseRequestProvider), 0);
    });
  });
}
