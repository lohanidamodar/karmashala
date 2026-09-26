import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala/src/features/notifications/presentation/attention_inbox_view.dart';
import 'package:karmashala_ui/tokens.dart';

void main() {
  final semantic = SemanticColors.forBrightness(Brightness.light);

  test('only the failure kinds take the failure colour', () {
    for (final kind in InboxItemKind.values) {
      final failing =
          kind == InboxItemKind.failed || kind == InboxItemKind.checksFailed;
      expect(
        inboxKindAppearance(kind, semantic).color == semantic.failure,
        failing,
        reason: kind.name,
      );
    }
  });

  test('a finished session and one ready to merge read as healthy', () {
    for (final kind in [InboxItemKind.finished, InboxItemKind.readyToMerge]) {
      expect(inboxKindAppearance(kind, semantic).color, semantic.idle);
    }
  });
}
