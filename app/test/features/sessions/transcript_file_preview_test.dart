import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/artifacts/presentation/artifact_pdf_view.dart';
import 'package:karmashala/src/features/artifacts/presentation/html_preview.dart';
import 'package:karmashala/src/features/sessions/application/file_preview_loader.dart';
import 'package:karmashala/src/features/sessions/domain/file_preview_kind.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/transcript_file_preview.dart';
import 'package:karmashala_ui/diagrams.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/transcript.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';
import '../../support/temp_directory.dart';

/// A file named in the conversation, previewed under its message: read
/// through the server wherever it lives, drawn by its kind, capped by size.
void main() {
  group('the loader reads through the server', () {
    late Directory box;
    late ProviderContainer container;

    File onBox(String posix) =>
        File(p.joinAll([box.path, ...posix.split('/').skip(1)]))
          ..createSync(recursive: true);

    Future<FilePreviewData> load(String environment, String posix) => container
        .read(filePreviewLoaderProvider)
        .load(EnvironmentPath(environmentId: environment, path: posix));

    for (final environment in const ['wsl:archlinux', 'ssh:box']) {
      group(environment, () {
        setUp(() async {
          box = Directory.systemTemp.createTempSync('ks-preview-');
          addTearDown(() => removeTempDirectory(box));
          final server = FakeDataServer()
            ..filesWork.posixAt(environment, box.path);
          container = ProviderContainer(
            overrides: [
              dataClientProvider.overrideWithValue(await server.connect()),
            ],
          );
          addTearDown(container.dispose);
        });

        test('a text file arrives whole, with its kind', () async {
          onBox(
            '/home/me/app/lib/main.dart',
          ).writeAsStringSync('void main() {}');
          final data = await load(environment, '/home/me/app/lib/main.dart');
          expect(data.kind, FilePreviewKind.code);
          expect(utf8.decode(data.bytes!), 'void main() {}');
          expect(data.cut, isFalse);
        });

        test('a large text file is cut, and says so', () async {
          onBox('/home/me/app/big.log').writeAsStringSync('x' * 400000);
          final data = await load(environment, '/home/me/app/big.log');
          expect(data.bytes!.length, kPreviewTextBytes);
          expect(data.size, 400000);
          expect(data.cut, isTrue);
        });

        test('binary is told by its bytes, not its name', () async {
          onBox('/home/me/app/data.txt').writeAsBytesSync([1, 0, 2, 3]);
          final data = await load(environment, '/home/me/app/data.txt');
          expect(data.binary, isTrue);
          expect(data.bytes, isNull);
        });

        test('a missing file and a folder say what they are', () async {
          Directory(
            p.join(box.path, 'home', 'me', 'dir'),
          ).createSync(recursive: true);
          expect(
            (await load(environment, '/home/me/gone.dart')).missing,
            isTrue,
          );
          expect((await load(environment, '/home/me/dir')).directory, isTrue);
        });

        test('an archive is not read at all', () async {
          onBox('/home/me/app/a.zip').writeAsBytesSync([80, 75, 3, 4]);
          final data = await load(environment, '/home/me/app/a.zip');
          expect(data.kind, FilePreviewKind.other);
          expect(data.size, 4);
          expect(data.bytes, isNull);
        });
      });
    }
  });

  testWidgets('a tapped path opens its preview under its own message', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ChatTranscriptView(
            messages: const [
              ChatMessage(role: 'user', text: 'where?'),
              ChatMessage(role: 'agent', text: 'It is in lib/main.dart:12.'),
              ChatMessage(role: 'agent', text: 'Done.'),
            ],
            onPathTap: tapped.add,
            filePreviewBuilder: (token, onClose) => TextButton(
              key: const ValueKey('fake-preview'),
              onPressed: onClose,
              child: Text('preview of $token'),
            ),
          ),
        ),
      ),
    );
    TapGestureRecognizer? link;
    for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
      widget.text.visitChildren((span) {
        if (span is TextSpan && span.recognizer is TapGestureRecognizer) {
          link ??= span.recognizer! as TapGestureRecognizer;
        }
        return true;
      });
    }
    link!.onTap!();
    await tester.pump();

    expect(find.text('preview of lib/main.dart:12'), findsOneWidget);
    expect(tapped, isEmpty, reason: 'the preview stands in for the reveal');
    // Under the message that named it, above the next one.
    expect(
      tester.getTopLeft(find.text('preview of lib/main.dart:12')).dy,
      lessThan(
        tester.getTopLeft(find.textContaining('Done.', findRichText: true)).dy,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('fake-preview')));
    await tester.pump();
    expect(find.byKey(const ValueKey('fake-preview')), findsNothing);
  });

  test('kinds by name', () {
    expect(previewKindFor('a/README.md'), FilePreviewKind.markdown);
    expect(previewKindFor(r'C:\x\shot.PNG'), FilePreviewKind.image);
    expect(previewKindFor('logo.svg'), FilePreviewKind.svg);
    expect(previewKindFor('doc.pdf'), FilePreviewKind.pdf);
    expect(previewKindFor('t.tsv'), FilePreviewKind.delimited);
    expect(previewKindFor('p.json'), FilePreviewKind.json);
    expect(previewKindFor('c.yml'), FilePreviewKind.yaml);
    expect(previewKindFor('page.html'), FilePreviewKind.html);
    expect(previewKindFor('flow.mmd'), FilePreviewKind.mermaid);
    expect(previewKindFor('build.log'), FilePreviewKind.log);
    expect(previewKindFor('lib/x.dart'), FilePreviewKind.code);
    expect(previewLanguageFor('x.tsx'), 'tsx');
    expect(previewLanguageFor('notes.txt'), isNull);
  });

  test('a quoted CSV keeps its commas and newlines', () {
    expect(parseDelimited('a,b\n"1,5","two\nlines"\n"say ""hi""",3'), [
      ['a', 'b'],
      ['1,5', 'two\nlines'],
      ['say "hi"', '3'],
    ]);
  });

  group('drawn by kind', () {
    Future<void> show(
      WidgetTester tester,
      String path,
      FilePreviewData data, {
      bool inScope = true,
      int? line,
      double width = 1440,
      double textScale = 1,
      Brightness brightness = Brightness.dark,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            filePreviewLoaderProvider.overrideWithValue(_Fixed(data)),
            artifactPdfViewProvider.overrideWithValue(
              (context, bytes) => Text('pdf ${bytes.length} bytes'),
            ),
          ],
          child: MaterialApp(
            theme: brightness == Brightness.dark
                ? AppTheme.dark()
                : AppTheme.light(),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: TranscriptFilePreview(
                    path: EnvironmentPath(environmentId: 'wsl', path: path),
                    line: line,
                    inScope: inScope,
                    onClose: () {},
                    onOpenInEditor: () {},
                    onOpenInFiles: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    FilePreviewData text(FilePreviewKind kind, String body, {int? size}) =>
        FilePreviewData(
          kind: kind,
          size: size ?? body.length,
          bytes: Uint8List.fromList(utf8.encode(body)),
          cut: size != null,
        );

    testWidgets('code, numbered and scrolled to its line', (tester) async {
      final source = List.generate(200, (i) => 'line_$i();').join('\n');
      await show(
        tester,
        '/repo/lib/a.dart',
        text(FilePreviewKind.code, source),
        line: 150,
      );
      expect(find.byType(NumberedCodeView), findsOneWidget);
      expect(find.byKey(const ValueKey('numbered-code-focus')), findsOneWidget);
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(NumberedCodeView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scroll.position.pixels, greaterThan(0));
      expect(find.text('a.dart'), findsNothing, reason: 'name is rich text');
      expect(find.textContaining('a.dart', findRichText: true), findsWidgets);
    });

    testWidgets('markdown, rendered', (tester) async {
      await show(
        tester,
        '/repo/README.md',
        text(FilePreviewKind.markdown, '# Title\n\nSome **bold** text.'),
      );
      expect(find.byType(MarkdownMessage), findsOneWidget);
    });

    testWidgets('CSV, as a table', (tester) async {
      await show(
        tester,
        '/repo/data.csv',
        text(FilePreviewKind.delimited, 'name,count\nalpha,1\nbeta,2'),
      );
      expect(find.byType(DataTableView), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
    });

    testWidgets('JSON, as a tree, and a broken one as source', (tester) async {
      await show(
        tester,
        '/repo/p.json',
        text(FilePreviewKind.json, '{"name":"app","deps":{"a":1}}'),
      );
      expect(find.byType(JsonTreeView), findsOneWidget);
      expect(find.textContaining('"app"', findRichText: true), findsOneWidget);

      await show(tester, '/repo/q.json', text(FilePreviewKind.json, '{oops'));
      expect(find.textContaining('Not valid JSON'), findsOneWidget);
      expect(find.byType(NumberedCodeView), findsOneWidget);
    });

    testWidgets('YAML, as a tree', (tester) async {
      await show(
        tester,
        '/repo/c.yaml',
        text(FilePreviewKind.yaml, 'name: app\nlist:\n  - one\n  - two\n'),
      );
      expect(find.byType(JsonTreeView), findsOneWidget);
      expect(
        find.textContaining('2 items', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('HTML, as the sandboxed preview with no script run', (
      tester,
    ) async {
      await show(
        tester,
        '/repo/page.html',
        text(FilePreviewKind.html, '<p>Hello</p><script>x()</script>'),
      );
      expect(find.byType(HtmlPreview), findsOneWidget);
      expect(
        find.byKey(const ValueKey('artifact-html-scripts')),
        findsOneWidget,
      );
    });

    testWidgets('mermaid, drawn', (tester) async {
      await show(
        tester,
        '/repo/flow.mmd',
        text(FilePreviewKind.mermaid, 'graph TD\n  A --> B'),
      );
      expect(find.byType(MermaidBlock), findsOneWidget);
    });

    testWidgets('a log, in its ANSI colours with the escapes gone', (
      tester,
    ) async {
      await show(
        tester,
        '/repo/build.log',
        text(FilePreviewKind.log, '\x1B[31mfailed\x1B[0m ok'),
      );
      expect(find.byType(AnsiText), findsOneWidget);
      expect(find.textContaining('[31m', findRichText: true), findsNothing);
      expect(
        find.textContaining('failed ok', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('a PDF, through the PDF viewer', (tester) async {
      await show(
        tester,
        '/repo/doc.pdf',
        FilePreviewData(
          kind: FilePreviewKind.pdf,
          size: 3,
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      );
      expect(find.text('pdf 3 bytes'), findsOneWidget);
    });

    testWidgets('an image that will not decode says so', (tester) async {
      await show(
        tester,
        '/repo/shot.png',
        FilePreviewData(
          kind: FilePreviewKind.image,
          size: 3,
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('a cut file says how much is shown', (tester) async {
      await show(
        tester,
        '/repo/big.txt',
        text(FilePreviewKind.code, 'abc', size: 3 * 1024 * 1024),
      );
      expect(find.byKey(const ValueKey('file-preview-cut')), findsOneWidget);
      expect(find.textContaining('of 3.0 MB'), findsOneWidget);
    });

    testWidgets('a binary file shows its size and type', (tester) async {
      await show(
        tester,
        '/repo/app.zip',
        const FilePreviewData(kind: FilePreviewKind.other, size: 2048),
      );
      expect(find.byKey(const ValueKey('file-preview-binary')), findsOneWidget);
      expect(find.textContaining('ZIP file · 2.0 KB'), findsOneWidget);
    });

    testWidgets('outside the checkout, nothing is read until asked', (
      tester,
    ) async {
      final loader = _Fixed(text(FilePreviewKind.code, 'secret'));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [filePreviewLoaderProvider.overrideWithValue(loader)],
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: TranscriptFilePreview(
                path: const EnvironmentPath(
                  environmentId: 'wsl',
                  path: '/etc/passwd',
                ),
                inScope: false,
                onClose: () {},
                onOpenInEditor: () {},
                onOpenInFiles: () {},
              ),
            ),
          ),
        ),
      );
      expect(loader.loads, 0);
      expect(find.text('Preview anyway'), findsOneWidget);
      await tester.tap(find.text('Preview anyway'));
      await tester.pump();
      await tester.pump();
      expect(loader.loads, 1);
    });

    for (final width in const [360.0, 390.0, 1440.0]) {
      for (final brightness in Brightness.values) {
        testWidgets('no overflow at $width px, text ×1.6, ${brightness.name}', (
          tester,
        ) async {
          await show(
            tester,
            '/home/me/a-rather-long-folder-name/and-another/deeper/file.dart',
            text(FilePreviewKind.code, 'final x = 1;\n' * 30),
            line: 3,
            width: width,
            textScale: 1.6,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          expect(find.text('Open in editor'), findsOneWidget);
          expect(find.text('Open in Files'), findsOneWidget);
        });
      }
    }
  });
}

class _Fixed implements FilePreviewLoader {
  _Fixed(this.data);

  final FilePreviewData data;
  int loads = 0;

  @override
  Future<FilePreviewData> load(EnvironmentPath path) async {
    loads++;
    return data;
  }
}
