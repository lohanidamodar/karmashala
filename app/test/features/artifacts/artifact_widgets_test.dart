import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/features/artifacts/application/artifact_actions.dart';
import 'package:karmashala/src/features/artifacts/application/artifact_providers.dart';
import 'package:karmashala/src/features/artifacts/data/artifacts_data.dart';
import 'package:karmashala/src/features/artifacts/presentation/artifact_card.dart';
import 'package:karmashala/src/features/artifacts/presentation/artifact_pdf_view.dart';
import 'package:karmashala/src/features/artifacts/presentation/artifact_screen.dart';
import 'package:karmashala/src/features/artifacts/presentation/artifact_viewer.dart';
import 'package:karmashala/src/features/artifacts/presentation/artifacts_panel.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_data_server.dart';
import 'artifacts_data_test.dart' show sampleArtifact;

const _phone = Size(390, 844);
const _desktop = Size(1440, 900);

void main() {
  late FakeDataServer server;
  late List<Uint8List> pdfs;

  setUp(() {
    server = FakeDataServer();
    pdfs = [];
  });

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Widget child, {
    Size size = _desktop,
    List<Override> more = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final data = await server.override();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          data,
          // pdfium is a native library the test runner does not load.
          artifactPdfViewProvider.overrideWithValue((context, bytes) {
            pdfs.add(bytes);
            return const SizedBox(key: ValueKey('fake-pdf-view'));
          }),
          ...more,
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
  }

  group('the card in the thread', () {
    for (final size in [_phone, _desktop]) {
      testWidgets('shows title, kind, revision and its actions at $size', (
        tester,
      ) async {
        final artifact = sampleArtifact();
        server.showArtifact(artifact, utf8.encode('<p>x</p>'));
        await pump(
          tester,
          ListView(children: [ArtifactCard(artifact: artifact)]),
          size: size,
        );
        expect(find.text('Chart a1'), findsOneWidget);
        expect(find.text('HTML · revision 1'), findsOneWidget);
        expect(find.byKey(const ValueKey('artifact-open-a1')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('artifact-open-browser')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('artifact-save')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a new revision redraws the card', (tester) async {
      final artifact = sampleArtifact();
      server.showArtifact(artifact, utf8.encode('one'));
      final container = await pump(
        tester,
        ListView(children: [ArtifactCard(artifact: artifact)]),
      );
      // The card follows the session's list, as the chat view keeps it read.
      final sub = container.listen(sessionArtifactsProvider('s1'), (_, _) {});
      addTearDown(sub.close);
      await tester.pumpAndSettle();
      server.showArtifact(sampleArtifact(revision: 2), utf8.encode('two'));
      await tester.pumpAndSettle();
      expect(find.text('HTML · revision 2'), findsOneWidget);
    });

    testWidgets('a small page is drawn in the card', (tester) async {
      final artifact = sampleArtifact(kind: ArtifactKind.markdown);
      server.showArtifact(artifact, utf8.encode('# Findings\n\nAll green.'));
      await pump(
        tester,
        ListView(children: [ArtifactCard(artifact: artifact)]),
        size: _phone,
      );
      expect(find.textContaining('All green.', findRichText: true), findsOneWidget);
    });

    testWidgets('Open goes full screen on a phone', (tester) async {
      final artifact = sampleArtifact();
      server.showArtifact(artifact, utf8.encode('<p>On the phone.</p>'));
      await pump(
        tester,
        ListView(children: [ArtifactCard(artifact: artifact)]),
        size: _phone,
      );
      await tester.tap(find.byKey(const ValueKey('artifact-open-a1')));
      await tester.pumpAndSettle();
      expect(find.byType(ArtifactScreen), findsOneWidget);
      expect(find.textContaining('On the phone.', findRichText: true), findsWidgets);
    });

    testWidgets('Open shows the side panel on a desktop', (tester) async {
      final artifact = sampleArtifact();
      server.showArtifact(artifact, utf8.encode('<p>x</p>'));
      final container = await pump(
        tester,
        ListView(children: [ArtifactCard(artifact: artifact)]),
      );
      await tester.tap(find.byKey(const ValueKey('artifact-open-a1')));
      await tester.pumpAndSettle();
      expect(container.read(sidePanelProvider), SidePanelSurface.artifacts);
      expect(container.read(selectedArtifactProvider), 'a1');
      expect(find.byType(ArtifactScreen), findsNothing);
    });
  });

  group('the viewer', () {
    Widget viewer() => const ArtifactViewer(sessionId: 's1', artifactId: 'a1');

    testWidgets('a page is drawn natively, and its scripts never run', (
      tester,
    ) async {
      server.showArtifact(
        sampleArtifact(),
        utf8.encode(
          '<h1>Report</h1><p style="color:#c00">All green.</p>'
          '<script>document.body.innerHTML = "hijacked"</script>',
        ),
      );
      await pump(tester, viewer());
      expect(find.textContaining('Report', findRichText: true), findsWidgets);
      expect(find.textContaining('All green.', findRichText: true), findsOneWidget);
      expect(find.textContaining('hijacked', findRichText: true), findsNothing);
      expect(
        find.byKey(const ValueKey('artifact-html-scripts')),
        findsOneWidget,
      );
    });

    testWidgets('a page with no script says nothing about scripts', (
      tester,
    ) async {
      server.showArtifact(sampleArtifact(), utf8.encode('<p>Plain.</p>'));
      await pump(tester, viewer());
      expect(find.byKey(const ValueKey('artifact-html-scripts')), findsNothing);
    });

    testWidgets('an image from the web is refused while the network is off, '
        'and a file never loads', (tester) async {
      server.showArtifact(
        sampleArtifact(),
        utf8.encode(
          '<img src="https://example.com/chart.png" alt="chart">'
          '<img src="file:///C:/Users/x/secret.png" alt="secret">',
        ),
      );
      await pump(tester, viewer());
      expect(
        find.byKey(const ValueKey('artifact-html-blocked-network')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('artifact-html-blocked-file')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('artifact-network')));
      await tester.pumpAndSettle();
      expect(server.artifacts['a1']!.networkAllowed, isTrue);
      expect(
        find.byKey(const ValueKey('artifact-html-blocked-network')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('artifact-html-blocked-file')),
        findsOneWidget,
        reason: 'a file is refused with the network allowed too',
      );
    });

    testWidgets('a rewrite reloads an open view; an old revision can be '
        'picked', (tester) async {
      server.showArtifact(sampleArtifact(), utf8.encode('<p>alpha</p>'));
      await pump(tester, viewer());
      server.showArtifact(
        sampleArtifact(revision: 2),
        utf8.encode('<p>bravo</p>'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('bravo', findRichText: true), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('artifact-revision')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revision 1').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('alpha', findRichText: true), findsWidgets);
      expect(find.textContaining('bravo', findRichText: true), findsNothing);
    });

    testWidgets('a PDF opens in the viewer here', (tester) async {
      server.showArtifact(
        sampleArtifact(kind: ArtifactKind.pdf),
        utf8.encode('%PDF-1.7'),
      );
      await pump(tester, viewer());
      expect(find.byKey(const ValueKey('fake-pdf-view')), findsOneWidget);
      expect(utf8.decode(pdfs.last), '%PDF-1.7');
    });

    testWidgets('a source gone from its host says so over the kept copy', (
      tester,
    ) async {
      server.showArtifact(
        sampleArtifact().copyWith(
          sourceState: ArtifactSourceState.missing,
          sourceProblem: () => 'No file at /w/r.html any more.',
        ),
        utf8.encode('<p>kept</p>'),
      );
      await pump(tester, viewer());
      expect(
        find.byKey(const ValueKey('artifact-note-sourceMissing')),
        findsOneWidget,
      );
      expect(find.textContaining('kept', findRichText: true), findsWidgets);
    });

    testWidgets('a host out of reach is said as such', (tester) async {
      server.showArtifact(
        sampleArtifact().copyWith(
          sourceState: ArtifactSourceState.unreachable,
          sourceProblem: () => 'connection refused',
        ),
        utf8.encode('<p>kept</p>'),
      );
      await pump(tester, viewer());
      expect(
        find.byKey(const ValueKey('artifact-note-hostUnreachable')),
        findsOneWidget,
      );
    });

    testWidgets('content the server will not serve says which refusal', (
      tester,
    ) async {
      server.showArtifact(sampleArtifact(), utf8.encode('<p>x</p>'));
      server.artifactContentRefusal = const DataRefused.unavailable(
        'the server is not running',
      );
      await pump(tester, viewer());
      expect(
        find.byKey(const ValueKey('artifact-fallback-serverUnreachable')),
        findsOneWidget,
      );
      expect(find.textContaining('the server is not running', findRichText: true), findsOneWidget);
    });

    testWidgets('Open in browser and Save act on the revision shown', (
      tester,
    ) async {
      final done = <String>[];
      server.showArtifact(sampleArtifact(), utf8.encode('<p>alpha</p>'));
      server.showArtifact(sampleArtifact(revision: 2), utf8.encode('<p>2</p>'));
      await pump(
        tester,
        viewer(),
        more: [
          artifactActionsProvider.overrideWith(
            (ref) => _RecordingActions(ref.watch(artifactsDataProvider), done),
          ),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('artifact-open-browser')));
      await tester.tap(find.byKey(const ValueKey('artifact-save')));
      await tester.pumpAndSettle();
      expect(done, ['browser a1 r2', 'save a1 r2']);
      expect(find.text('opened'), findsOneWidget);
    });
  });

  group('the Artifacts panel', () {
    for (final size in [_phone, _desktop]) {
      testWidgets('lists the session\'s artifacts, newest first, and opens '
          'the newest at $size', (tester) async {
        server.showArtifact(
          sampleArtifact(id: 'a1', at: DateTime.utc(2026, 10, 6, 9)),
          utf8.encode('<p>1</p>'),
        );
        server.showArtifact(
          sampleArtifact(
            id: 'a2',
            kind: ArtifactKind.markdown,
            at: DateTime.utc(2026, 10, 6, 10),
          ),
          utf8.encode('# second'),
        );
        await pump(
          tester,
          const ArtifactsPanel(),
          size: size,
          more: [panelSessionIdProvider.overrideWithValue('s1')],
        );
        final rows = tester
            .widgetList<ListTile>(find.byType(ListTile))
            .map((t) => t.key)
            .toList();
        expect(rows, [
          const ValueKey('artifact-row-a2'),
          const ValueKey('artifact-row-a1'),
        ]);
        expect(find.byKey(const ValueKey('artifact-viewer-a2')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a session with nothing shown says how to show something', (
      tester,
    ) async {
      await pump(
        tester,
        const ArtifactsPanel(),
        more: [panelSessionIdProvider.overrideWithValue('s1')],
      );
      expect(find.textContaining('artifact_show', findRichText: true), findsOneWidget);
    });
  });
}

class _RecordingActions extends ArtifactActions {
  _RecordingActions(super.data, this.done);

  final List<String> done;

  @override
  Future<String> openInBrowser(Artifact artifact, int revision) async {
    done.add('browser ${artifact.id} r$revision');
    return 'opened';
  }

  @override
  Future<String?> save(Artifact artifact, int revision) async {
    done.add('save ${artifact.id} r$revision');
    return 'saved';
  }
}
