import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/acp_agent_icon_providers.dart';
import 'package:karmashala/src/features/agents/application/acp_agent_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/presentation/agent_logo.dart';
import 'package:karmashala_ui/icons.dart';

import '../../support/fake_http_client.dart';
import '../../support/fixtures.dart';

/// What stands for an agent wherever one is drawn: the shipped logo for a
/// mark, the registry's icon for a person-added agent (fetched once, kept on
/// disk), and the adapter's glyph for everything else and until then.
void main() {
  const svg =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">'
      '<path d="M0 0h16v16H0z" fill="currentColor"/></svg>';
  const iconUrl = 'https://cdn.example.test/registry/native-agent.svg';

  final row = AcpAgentRow(
    id: 'r1',
    name: 'Native Agent',
    command: 'native-agent',
    source: AcpAgentSource.registry,
    registryId: 'native-agent',
    iconUrl: iconUrl,
    createdAt: testTime,
  );
  final registry = AgentRegistry.withExtra([acpAgentAdapter(row)]);

  group('the icon cache', () {
    late Directory cache;
    late FakeHttpClient http;

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('ks-icons-');
      http = FakeHttpClient(body: svg);
    });
    tearDown(() => cache.delete(recursive: true));

    ProviderContainer container() {
      final scope = ProviderContainer(
        overrides: [
          acpAgentIconCacheDirectoryProvider.overrideWith((ref) async => cache),
          acpRegistryHttpClientProvider.overrideWithValue(() => http),
        ],
      );
      addTearDown(scope.dispose);
      return scope;
    }

    // Held by a listener while it loads, as a widget would hold it.
    Future<String?> read(ProviderContainer scope) {
      scope.listen(acpAgentIconProvider(iconUrl), (_, _) {});
      return scope.read(acpAgentIconProvider(iconUrl).future);
    }

    test('fetches once, keeps the SVG on disk, and reads it back', () async {
      final first = await read(container());
      expect(first, svg);
      expect(http.requestedUrls, [Uri.parse(iconUrl)]);
      expect(
        File('${cache.path}/${iconCacheFileName(iconUrl)}').readAsStringSync(),
        svg,
      );

      // A second look reads the file and asks the registry nothing.
      http = FakeHttpClient(body: 'unused');
      final again = await read(container());
      expect(again, svg);
      expect(http.requests, 0);
    });

    test(
      'an icon that cannot be fetched is none, and nothing is kept',
      () async {
        http = FakeHttpClient(statusCode: 500, body: 'no');
        expect(await read(container()), isNull);
        expect(cache.listSync(), isEmpty);
      },
    );

    test('something that is not an SVG is none', () async {
      http = FakeHttpClient(body: '<html>not found</html>');
      expect(await read(container()), isNull);
      expect(cache.listSync(), isEmpty);
      http.throwOnRequest = const SocketException('offline');
      expect(await read(container()), isNull);
    });

    test('the cache file name is stable, safe, and tells two URLs apart', () {
      final a = iconCacheFileName('https://cdn.example.test/a/x.svg');
      final b = iconCacheFileName('https://cdn.example.test/b/x.svg');
      expect(a, endsWith('-x.svg'));
      expect(a, isNot(b));
      expect(a, iconCacheFileName('https://cdn.example.test/a/x.svg'));
      expect(
        iconCacheFileName('https://x.test/we ird?q=1'),
        matches(RegExp(r'^[0-9a-f]{8}-[A-Za-z0-9._-]+\.svg$')),
      );
    });
  });

  group('the widget', () {
    // What the icon provider answers for the row: unresolved by default.
    late FutureOr<String?> Function() icon;

    setUp(() => icon = () => Completer<String?>().future);

    Future<void> pump(WidgetTester tester, String agentId) async {
      await tester.pumpWidget(
        // A fresh scope each time: a root of the same type would be kept,
        // and its provider with it.
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            agentRegistryProvider.overrideWithValue(registry),
            acpAgentIconProvider.overrideWith((ref, url) {
              expect(url, iconUrl);
              return icon();
            }),
          ],
          child: MaterialApp(
            home: Scaffold(body: AgentLogo(agentId: agentId, size: 16)),
          ),
        ),
      );
    }

    IconData? iconShown(WidgetTester tester) =>
        tester.widgetList<Icon>(find.byType(Icon)).singleOrNull?.icon;

    testWidgets('a shipped mark is the logo the app ships', (tester) async {
      await pump(tester, AgentIds.claudeCode);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('an agent without a mark wears its adapter\'s glyph', (
      tester,
    ) async {
      await pump(tester, AgentIds.grok);
      expect(iconShown(tester), AppIcons.rocketLaunch);
      await pump(tester, 'nobody');
      expect(iconShown(tester), AppIcons.robot);
    });

    testWidgets('a registry icon is the glyph until known, then the SVG', (
      tester,
    ) async {
      await pump(tester, row.agentId);
      expect(iconShown(tester), AppIcons.robot);
      expect(find.byType(SvgPicture), findsNothing);

      icon = () => svg;
      await pump(tester, row.agentId);
      await tester.pump();
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('a registry icon that could not be had leaves the glyph', (
      tester,
    ) async {
      icon = () => null;
      await pump(tester, row.agentId);
      await tester.pump();
      expect(iconShown(tester), AppIcons.robot);
      expect(find.byType(SvgPicture), findsNothing);
    });
  });
}
