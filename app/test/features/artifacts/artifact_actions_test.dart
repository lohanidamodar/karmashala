import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/artifacts/application/artifact_actions.dart';
import 'package:karmashala/src/features/artifacts/data/artifacts_data.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';
import 'artifacts_data_test.dart' show sampleArtifact;

/// Open in browser and Save work from the bytes the server serves — the
/// revision asked for, on any client — and never write outside their folder.
void main() {
  late FakeDataServer server;
  late ProviderContainer container;
  late Directory tmp;

  setUp(() async {
    server = FakeDataServer();
    container = ProviderContainer(overrides: [await server.override()]);
    tmp = Directory.systemTemp.createTempSync('artifact-actions');
    addTearDown(() {
      container.dispose();
      tmp.deleteSync(recursive: true);
    });
  });

  ArtifactActions actions({
    List<Uri>? launched,
    Future<String?> Function(String name)? saveLocation,
  }) => ArtifactActions(
    container.read(artifactsDataProvider),
    launch: (uri) async {
      launched?.add(uri);
      return true;
    },
    saveLocation: saveLocation,
    scratch: () async => tmp,
    documents: () async => tmp,
  );

  test('Open in browser writes the revision asked for and opens it', () async {
    const md = ArtifactKind.markdown;
    server.showArtifact(sampleArtifact(kind: md), utf8.encode('# one'));
    server.showArtifact(
      sampleArtifact(kind: md, revision: 2),
      utf8.encode('# two'),
    );
    final launched = <Uri>[];

    final said = await actions(
      launched: launched,
    ).openInBrowser(sampleArtifact(kind: md, revision: 2), 1);

    expect(File.fromUri(launched.single).readAsStringSync(), '# one');
    expect(p.isWithin(tmp.path, launched.single.toFilePath()), isTrue);
    expect(said, contains('outside Karmashala'));
  });

  test('a page goes to the browser inside the sandbox, network as allowed',
      () async {
    server.showArtifact(sampleArtifact(), utf8.encode('<h1>Report</h1>'));
    final launched = <Uri>[];
    await actions(launched: launched).openInBrowser(sampleArtifact(), 1);
    final opened = File.fromUri(launched.single).readAsStringSync();
    expect(opened, contains('sandbox="allow-scripts"'));
    expect(opened, contains("connect-src 'none'"));
    expect(opened, contains('&lt;h1&gt;Report&lt;/h1&gt;'));

    final allowed = sampleArtifact().copyWith(networkAllowed: true);
    await actions(launched: launched).openInBrowser(allowed, 1);
    expect(
      File.fromUri(launched.last).readAsStringSync(),
      contains('connect-src https:'),
    );
  });

  test('an image goes to the browser as it is', () async {
    final image = sampleArtifact(kind: ArtifactKind.image);
    server.showArtifact(image, [137, 80, 78, 71]);
    final launched = <Uri>[];
    await actions(launched: launched).openInBrowser(image, 1);
    expect(File.fromUri(launched.single).readAsBytesSync(), [137, 80, 78, 71]);
  });

  test('a file name cannot walk out of its folder', () async {
    final base = sampleArtifact();
    final hostile = Artifact(
      id: base.id,
      sessionId: base.sessionId,
      title: base.title,
      kind: base.kind,
      mode: base.mode,
      origin: base.origin,
      fileName: r'..\..\evil.html',
      revision: 1,
      size: 1,
      mimeType: base.mimeType,
      createdAt: base.createdAt,
      updatedAt: base.updatedAt,
    );
    server.showArtifact(hostile, utf8.encode('x'));
    final launched = <Uri>[];
    await actions(launched: launched).openInBrowser(hostile, 1);
    expect(p.isWithin(tmp.path, launched.single.toFilePath()), isTrue);
    expect(p.basename(launched.single.toFilePath()), 'evil.html');
  });

  test('Save writes where the person chose', () async {
    server.showArtifact(sampleArtifact(), utf8.encode('<p>s</p>'));
    final where = p.join(tmp.path, 'chosen.html');
    final said = await actions(
      saveLocation: (_) async => where,
    ).save(sampleArtifact(), 1);
    expect(File(where).readAsStringSync(), '<p>s</p>');
    expect(said, contains(where));
  });

  test('Save cancelled writes nothing and says nothing', () async {
    server.showArtifact(sampleArtifact(), utf8.encode('x'));
    final said = await actions(
      saveLocation: (_) async => null,
    ).save(sampleArtifact(), 1);
    expect(said, isNull);
  });

  test('with no save dialog, it is kept in the app\'s folder and says where',
      () async {
    server.showArtifact(sampleArtifact(), utf8.encode('<p>k</p>'));
    final said = await actions(
      saveLocation: (_) async => throw UnimplementedError('no dialog'),
    ).save(sampleArtifact(), 1);
    final kept = File(p.join(tmp.path, 'artifacts', 'a1.html'));
    expect(kept.readAsStringSync(), '<p>k</p>');
    expect(said, contains(kept.path));
  });
}

