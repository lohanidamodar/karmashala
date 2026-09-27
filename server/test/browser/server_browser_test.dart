import 'dart:async';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/browser/server_browser.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_browser.dart';

/// The server's browser (slice 3d): what every pane is told, what a person's
/// requests do, and the lifetime of a Chrome the server launched. Chrome is
/// a fake answering CDP in Dart; nothing is ever launched.
void main() {
  late AppDatabase db;
  late Directory data;
  late List<DataChange> told;

  setUp(() {
    db = AppDatabase.memory();
    data = Directory.systemTemp.createTempSync('server-browser-');
    told = [];
  });
  tearDown(() {
    db.close();
    if (data.existsSync()) data.deleteSync(recursive: true);
  });

  ServerBrowser browserOver(
    FakeBrowser fake, {
    Map<String, String> environment = const {},
    String operatingSystem = 'macos',
  }) {
    final browser = ServerBrowser(
      database: db,
      dataDirectory: data.path,
      tell: told.addAll,
      hostEnvironment: environment,
      operatingSystem: operatingSystem,
      service: fake.service,
    );
    addTearDown(browser.close);
    return browser;
  }

  List<BrowserState> states() => [
    for (final change in told)
      if (change case BrowserStateChanged(:final state)) state,
  ];

  Matcher refused(String words) => throwsA(
    isA<DataRefused>().having((r) => r.message, 'message', contains(words)),
  );

  group('what every client is told', () {
    test('a new client is greeted with a browser in use, and not with an '
        'idle one', () async {
      final browser = browserOver(FakeBrowser());
      expect(browser.greeting(), isEmpty);
      await browser.handle(const BrowserConnect());
      final greeting = browser.greeting().single as BrowserStateChanged;
      expect(greeting.state.status, BrowserStatus.connected);
      expect(greeting.state.headless, isFalse);
    });

    test('attaching says which browser, where it is and its tabs', () async {
      final fake = FakeBrowser(
        targets: [
          fakeTarget('PAGE-1'),
          fakeTarget('PAGE-2', title: 'Two'),
        ],
      );
      final browser = browserOver(fake);
      final state =
          await browser.handle(const BrowserConnect()) as BrowserState;
      expect(state.status, BrowserStatus.connected);
      expect(state.connection, contains('Attached'));
      expect(state.url, 'https://example.com/app');
      expect(state.title, 'Example');
      expect(state.tabs.map((t) => t.id), ['PAGE-1', 'PAGE-2']);
      expect(state.currentTargetId, 'PAGE-1');
      expect(states().first.status, BrowserStatus.connecting);
      expect(states().last.status, BrowserStatus.connected);
    });

    test(
      'a browser that goes away stops being reported as connected',
      () async {
        final fake = FakeBrowser();
        final browser = browserOver(fake);
        await browser.connect();
        fake.socket.drop();
        await Future<void>.delayed(Duration.zero);
        expect(browser.state.status, BrowserStatus.disconnected);
        expect(browser.state.error, contains('The browser disconnected'));
        expect(states().last.status, BrowserStatus.disconnected);
      },
    );

    test('disconnecting on purpose is not reported as a failure', () async {
      final browser = browserOver(FakeBrowser());
      await browser.connect();
      await browser.handle(const BrowserDisconnect());
      await Future<void>.delayed(Duration.zero);
      expect(browser.state.status, BrowserStatus.disconnected);
      expect(browser.state.error, isNull);
    });
  });

  group('a person\'s requests', () {
    test('adds a scheme so localhost:3000 is not read as one', () async {
      final fake = FakeBrowser();
      final browser = browserOver(fake);
      final state =
          await browser.handle(const BrowserNavigate('localhost:3000'))
              as BrowserState;
      expect(
        fake.framesFor('Page.navigate').single['url'],
        'http://localhost:3000',
      );
      expect(state.status, BrowserStatus.connected);
    });

    test('leaves a real URL alone', () async {
      final fake = FakeBrowser();
      final browser = browserOver(fake);
      await browser.connect();
      await browser.handle(const BrowserNavigate('https://example.com/x?y=1'));
      expect(
        fake.framesFor('Page.navigate').single['url'],
        'https://example.com/x?y=1',
      );
    });

    test(
      'switching tabs drives the other page, with no false failure',
      () async {
        final fake = FakeBrowser(
          targets: [fakeTarget('PAGE-1'), fakeTarget('PAGE-2')],
        );
        final browser = browserOver(fake);
        await browser.connect();
        final state =
            await browser.handle(const BrowserSelectTab('PAGE-2'))
                as BrowserState;
        await Future<void>.delayed(Duration.zero);
        expect(fake.service.session!.page.target.id, 'PAGE-2');
        expect(state.currentTargetId, 'PAGE-2');
        expect(browser.state.status, BrowserStatus.connected);
        expect(browser.state.error, isNull);
      },
    );

    test(
      'a failure is refused in the browser\'s own words, and shown',
      () async {
        final fake = FakeBrowser(spawn: true);
        final browser = browserOver(fake);
        await expectLater(
          browser.handle(const BrowserConnect(spawn: false)),
          refused('9222'),
        );
        expect(browser.state.status, BrowserStatus.disconnected);
        expect(browser.state.error, contains('9222'));
        expect(fake.starts, isEmpty);
      },
    );

    test('a screenshot is the viewport\'s PNG', () async {
      final browser = browserOver(FakeBrowser());
      await browser.connect();
      final png = await browser.handle(const BrowserScreenshot()) as List<int>;
      expect(png.take(4), [0x89, 0x50, 0x4e, 0x47]);
    });

    test('an expression answers its value as text', () async {
      final fake = FakeBrowser()..onEvaluate = (e) => e == '1 + 1' ? 2 : null;
      final browser = browserOver(fake);
      await browser.connect();
      expect(await browser.handle(const BrowserEvaluate('1 + 1')), '2');
    });
  });

  group('picking an element', () {
    test('a pick lands as the element, its picture written beside the '
        'server\'s data', () async {
      final fake = FakeBrowser();
      final browser = browserOver(fake);
      await browser.connect();
      final pending = browser.handle(const BrowserPickElement());
      await pumpEventQueue();
      expect(browser.state.status, BrowserStatus.picking);
      fake.click();
      final pick = await pending as BrowserPick;
      expect(pick.capture.selector, '#hero');
      expect(pick.captureFile, startsWith(p.join(data.path, 'captures')));
      expect(File(pick.captureFile!).existsSync(), isTrue);
      expect(pick.promptText, contains('Screenshot file: ${pick.captureFile}'));
      expect(browser.state.status, BrowserStatus.connected);
    });

    test('a cancelled pick is refused and says so', () async {
      final browser = browserOver(FakeBrowser());
      await browser.connect();
      final pending = browser.handle(const BrowserPickElement());
      await pumpEventQueue();
      await browser.handle(const BrowserCancelPick());
      await expectLater(pending, refused('cancelled'));
      expect(browser.state.error, contains('cancelled'));
    });

    test('so is one nobody ever clicked', () async {
      final browser = browserOver(
        FakeBrowser(pickTimeout: const Duration(milliseconds: 40)),
      );
      await browser.connect();
      await expectLater(
        browser.handle(const BrowserPickElement()),
        refused('did not answer in time'),
      );
    });

    test(
      'a headless server refuses a pick in words, before asking the page',
      () async {
        final fake = FakeBrowser();
        final browser = browserOver(
          fake,
          environment: const {},
          operatingSystem: 'linux',
        );
        expect(browser.headless, isTrue);
        expect(browser.state.headless, isTrue);
        await browser.connect();
        await expectLater(
          browser.handle(const BrowserPickElement()),
          refused('headless'),
        );
        expect(browser.state.status, BrowserStatus.connected);
      },
    );
  });

  group('a browser the server launched', () {
    test('is killed, and its throwaway profile deleted, when the server '
        'closes', () async {
      final fake = FakeBrowser(spawn: true, temp: data);
      final browser = browserOver(fake);
      await browser.connect();
      expect(fake.starts, hasLength(1));
      expect(browser.state.connection, contains('Launched'));
      final profile = fake.profiles.single;
      expect(profile.existsSync(), isTrue);

      // Reattaching to it (now listening) must not lose the ownership.
      await browser.disconnect();
      await browser.connect();
      await browser.close();
      expect(fake.process.killed, isTrue);
      expect(profile.existsSync(), isFalse);
    });

    test('an attached browser — the person\'s own — is never killed', () async {
      final fake = FakeBrowser(temp: data);
      final browser = browserOver(fake);
      await browser.connect();
      await browser.close();
      expect(fake.starts, isEmpty);
      expect(fake.process.killed, isFalse);
    });
  });
}
