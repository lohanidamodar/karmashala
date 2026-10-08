import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:karmashala_ui/tokens.dart';

typedef ArtifactPdfViewBuilder =
    Widget Function(BuildContext context, Uint8List bytes);

/// How a PDF artifact is drawn: pdfrx's viewer (pdfium) — zoom, scroll, and
/// selectable text. A provider so a test needs no native pdfium.
final artifactPdfViewProvider = Provider<ArtifactPdfViewBuilder>(
  (ref) =>
      (context, bytes) => PdfViewer.data(
        bytes,
        sourceName: 'artifact-${bytes.hashCode}',
        params: PdfViewerParams(
          errorBannerBuilder: (context, error, stackTrace, documentRef) =>
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(Insets.lg),
                  child: Text(
                    'This PDF could not be opened: $error',
                    key: const ValueKey('artifact-pdf-failed'),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
        ),
      ),
);
