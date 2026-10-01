import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/editor/application/media_documents.dart';
import 'package:karmashala/src/features/editor/domain/media_document.dart';
import 'package:karmashala/src/features/editor/domain/media_kind.dart';
import 'package:karmashala/src/features/editor/presentation/media/image_viewer.dart';
import 'package:karmashala/src/features/editor/presentation/media/media_tab_view.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/desktop_client.dart';

const _image = r'C:\repo\shots\home.png';
const _video = r'C:\repo\shots\run.mp4';

/// A 1×1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

/// The files as given, and nothing read from any disk.
class _FakeMedia extends MediaDocuments {
  _FakeMedia(this.seed);

  final Map<String, MediaDocument> seed;

  @override
  Map<String, MediaDocument> build() => seed;

  @override
  Future<void> open(String hostPath) async {}

  @override
  Future<void> reload(String hostPath) async {}

  @override
  void close(String hostPath) {}
}

/// A phone: touch density and no media backend.
ClientCapabilities _phone() {
  final desktop = desktopClient(density: UiDensity.touch);
  return ClientCapabilities(
    systemIntegration: false,
    osToasts: false,
    localNotifications: true,
    localDevices: false,
    externalApps: false,
    fileDrop: false,
    relaunch: false,
    density: UiDensity.touch,
    hostsServer: false,
    multicastLock: true,
    mediaPlayback: false,
    deviceName: desktop.deviceName,
    camera: true,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required String hostPath,
  required MediaDocument document,
  ClientCapabilities? client,
  VoidCallback? onAttachToChat,
  String? attachDisabledReason,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mediaDocumentsProvider.overrideWith(
          () => _FakeMedia({hostPath: document}),
        ),
        clientCapabilitiesProvider.overrideWithValue(client ?? desktopClient()),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: MediaTabView(
              hostPath: hostPath,
              onCopyPath: () {},
              onOpenExternally: () {},
              onAttachToChat: onAttachToChat,
              attachDisabledReason: attachDisabledReason,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('an image shows the viewer, its zoom and its status line', (
    tester,
  ) async {
    await _pump(
      tester,
      hostPath: _image,
      document: MediaDocument(
        hostPath: _image,
        kind: MediaKind.image,
        bytes: _png,
      ),
      onAttachToChat: () {},
    );

    expect(find.byType(ImageViewer), findsOneWidget);
    expect(find.text('Fit'), findsOneWidget);
    expect(find.byTooltip('Copy image'), findsOneWidget);
    // The size and format are known before the image decodes.
    expect(find.textContaining('${_png.length} B · PNG'), findsOneWidget);
  });

  testWidgets('a refused file says why instead of showing anything', (
    tester,
  ) async {
    await _pump(
      tester,
      hostPath: _image,
      document: const MediaDocument(
        hostPath: _image,
        kind: MediaKind.image,
        refusal: MediaRefusal.tooLarge,
        error: 'home.png is 300 MB; too large to show here.',
      ),
    );

    expect(
      find.text('home.png is 300 MB; too large to show here.'),
      findsOneWidget,
    );
    expect(find.byType(ImageViewer), findsNothing);
    expect(find.text('Open externally'), findsOneWidget);
  });

  testWidgets('a video on a phone offers what it can instead of a player', (
    tester,
  ) async {
    await _pump(
      tester,
      hostPath: _video,
      client: _phone(),
      document: const MediaDocument(
        hostPath: _video,
        kind: MediaKind.video,
        localPath: r'C:\cache\run.mp4',
      ),
      onAttachToChat: () {},
    );

    expect(
      find.text("Playback on this device isn't supported yet."),
      findsOneWidget,
    );
    expect(find.text('Copy path'), findsOneWidget);
    expect(find.text('Attach to chat'), findsOneWidget);
    expect(find.byTooltip('Copy image'), findsNothing);
  });

  testWidgets('attach is disabled, with its reason, without a callback', (
    tester,
  ) async {
    const reason = 'Open a session to attach this to.';
    await _pump(
      tester,
      hostPath: _image,
      document: MediaDocument(
        hostPath: _image,
        kind: MediaKind.image,
        bytes: _png,
      ),
      attachDisabledReason: reason,
    );

    expect(find.byTooltip(reason), findsOneWidget);
    final attach = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(AppIcons.chat),
        matching: find.byType(IconButton),
      ),
    );
    expect(attach.onPressed, isNull);
  });

  test('the status line names size, bytes and format', () {
    expect(
      mediaStatusLine(
        width: 1280,
        height: 720,
        byteCount: 84 * 1024,
        name: 'shot.png',
      ),
      '1280×720 · 84 KB · PNG',
    );
    expect(
      mediaStatusLine(byteCount: 3 * 1024 * 1024, name: 'a.jpg'),
      '3.0 MB · JPEG',
    );
  });
}
