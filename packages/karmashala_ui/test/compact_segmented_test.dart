import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

/// The house segmented picker: [CompactSegmented.tight] narrows the padding
/// beside each label, never the target's height.
void main() {
  Future<Size> segmentSize(WidgetTester tester, {required bool tight}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CompactSegmented<int>(
              tight: tight,
              segments: const [
                ButtonSegment(value: 0, label: Text('Automations')),
                ButtonSegment(value: 1, label: Text('Runs')),
              ],
              selected: 0,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    return tester.getSize(find.byType(SegmentedButton<int>));
  }

  testWidgets('tight is narrower, and as tall', (tester) async {
    final roomy = await segmentSize(tester, tight: false);
    final tight = await segmentSize(tester, tight: true);
    expect(tight.width, lessThan(roomy.width));
    expect(tight.height, roomy.height);
    expect(tight.width, greaterThan(Insets.xs * 4));
  });
}
