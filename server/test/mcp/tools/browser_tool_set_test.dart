import 'package:karmashala_browser/tools.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/browser/server_browser.dart';
import 'package:karmashala_host/src/mcp/tools/browser_tool_set.dart';
import 'package:test/test.dart';

import '../../support/fake_browser.dart';
import 'tool_harness.dart';

/// `browser_*` as the server runs them (slice 3d): over its own browser,
/// under the caller's project consent, with every client's pane told what
/// an agent did.
void main() {
  late ToolHarness h;
  late FakeBrowser fake;
  late List<DataChange> told;

  setUp(() {
    h = ToolHarness();
    fake = FakeBrowser();
    told = [];
  });
  tearDown(() => h.dispose());

  BrowserToolSet toolsOver({String operatingSystem = 'macos'}) {
    final browser = ServerBrowser(
      database: h.db,
      dataDirectory: h.tmp.path,
      tell: told.addAll,
      hostEnvironment: const {},
      operatingSystem: operatingSystem,
      service: fake.service,
    );
    addTearDown(browser.close);
    return BrowserToolSet(browser);
  }

  test('serves the package\'s schemas, every one', () {
    expect(
      toolsOver().schemas.map((s) => s['name']),
      browserToolSchemas.map((s) => s['name']),
    );
  });

  test('an agent\'s navigation reaches every pane', () async {
    final tools = toolsOver();
    await h.call(tools, 'browser_navigate', {
      'url': 'https://example.com/app',
    }, 's1');
    final last = told.whereType<BrowserStateChanged>().last.state;
    expect(last.status, BrowserStatus.connected);
    expect(last.url, 'https://example.com/app');
    expect(last.tabs, isNotEmpty);
  });

  test('evaluating is refused until the caller\'s project granted it', () {
    final tools = toolsOver();
    expect(
      h.call(tools, 'browser_evaluate', {'expression': '1'}, 's1'),
      throwsA(
        isA<BrowserToolException>().having(
          (e) => e.message,
          'message',
          contains('"Demo"'),
        ),
      ),
    );
    expect(
      h.call(tools, 'browser_evaluate', {'expression': '1'}),
      throwsA(isA<BrowserToolException>()),
      reason: 'no session, no project: fail closed',
    );
  });

  test('a headless server refuses browser_pick in words', () {
    final tools = toolsOver(operatingSystem: 'linux');
    expect(
      h.call(tools, 'browser_pick', const {}, 's1'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('headless'),
        ),
      ),
    );
  });

  test('never hands a call to the app, even with nothing attached', () async {
    final answer = toolsOver().call('browser_tabs', const {}, null);
    expect(answer, isNotNull);
    await expectLater(answer, throwsA(isA<BrowserToolException>()));
  });
}
