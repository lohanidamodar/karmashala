import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open_list.dart';
import 'package:karmashala_ui/icons.dart';

void main() {
  testWidgets('a long detail ends rather than pushing the row out', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: QuickOpenRow(
                icon: AppIcons.terminal,
                title: 'zsh',
                subtitle: 'Karmashala · app',
                detail: 'current · running claude in session/fix-the-login',
                selected: false,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('current · running'), findsOneWidget);
  });
}
