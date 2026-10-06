import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/artifacts/application/artifact_providers.dart';
import 'package:karmashala/src/features/artifacts/data/artifacts_data.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';

Artifact sampleArtifact({
  String id = 'a1',
  String sessionId = 's1',
  int revision = 1,
  ArtifactKind kind = ArtifactKind.html,
  DateTime? at,
}) => Artifact(
  id: id,
  sessionId: sessionId,
  title: 'Chart $id',
  kind: kind,
  mode: ArtifactMode.inline,
  origin: ArtifactOrigin.tool,
  hasSource: true,
  fileName: '$id.${kind.extension}',
  revision: revision,
  size: 10,
  mimeType: artifactMimeType(kind, '$id.${kind.extension}'),
  createdAt: at ?? DateTime.utc(2026, 10, 6, 9),
  updatedAt: at ?? DateTime.utc(2026, 10, 6, 9),
);

void main() {
  late FakeDataServer server;
  late ProviderContainer container;

  setUp(() async {
    server = FakeDataServer();
    container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
  });

  ArtifactsData data() => container.read(artifactsDataProvider);

  test('a session\'s list is asked once, then kept by what is told', () async {
    server.showArtifact(sampleArtifact(), utf8.encode('<p>1</p>'));
    expect((await data().forSession('s1')).single.revision, 1);

    final asked = server.requests.length;
    server.showArtifact(sampleArtifact(revision: 2), utf8.encode('<p>2</p>'));
    final again = await data().forSession('s1');
    expect(again.single.revision, 2);
    expect(server.requests.length, asked, reason: 'kept, not re-asked');
  });

  test('content is read over the data channel in chunks', () async {
    final big = Uint8List.fromList(
      List.generate(kFileChunkBytes * 2 + 17, (i) => i % 251),
    );
    server.showArtifact(sampleArtifact(kind: ArtifactKind.image), big);
    final bytes = await data().content('a1', 1);
    expect(bytes, big);
  });

  test('an old revision is read as it was', () async {
    server.showArtifact(sampleArtifact(), utf8.encode('one'));
    server.showArtifact(sampleArtifact(revision: 2), utf8.encode('two'));
    expect(utf8.decode(await data().content('a1', 1)), 'one');
    expect(utf8.decode(await data().content('a1', 2)), 'two');
  });

  test('the providers move when an artifact is revised', () async {
    server.showArtifact(sampleArtifact(), utf8.encode('one'));
    final sub = container.listen(sessionArtifactsProvider('s1'), (_, _) {});
    addTearDown(sub.close);
    expect((await container.read(sessionArtifactsProvider('s1').future)).single.revision, 1);

    server.showArtifact(sampleArtifact(revision: 2), utf8.encode('two'));
    await Future<void>.delayed(Duration.zero);
    expect((await container.read(sessionArtifactsProvider('s1').future)).single.revision, 2);
  });

  test('allowing the network is the server\'s setting', () async {
    server.showArtifact(sampleArtifact(), utf8.encode('x'));
    final allowed = await data().setNetwork('a1', allowed: true);
    expect(allowed.networkAllowed, isTrue);
    expect(server.artifacts['a1']!.networkAllowed, isTrue);
  });
}
