import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/stores/presentation/store_installs.dart';
import 'package:store_console/store_console.dart';

void main() {
  final exact = InstallTotal(
    count: 12345,
    measure: 'user installs',
    source: InstallTotalSource.reports,
    since: '2024-03',
    through: DateTime.utc(2026, 9, 29),
  );
  final band = InstallTotal.fromBand(
    '10K+',
    note: 'Add your reports bucket in Settings → Stores.',
  )!;

  test('an exact count is compact; a band is shown as the listing has it', () {
    expect(formatInstallFigure(exact), isNot(contains('+')));
    expect(formatInstallFigure(band), '10K+');
  });

  test('the measure says what is counted and since when', () {
    expect(describeInstallMeasure(exact), 'user installs since Mar 2024');
    expect(describeInstallMeasure(band), 'installs, Play listing band');
    expect(formatInstallPeriod('2021'), '2021');
  });

  test('the tooltip gives the exact number, source and as-of', () {
    final exactText = describeInstallTotal(exact, StoreKind.googlePlay);
    expect(exactText, contains('12,345'));
    expect(exactText, contains('2026-09-29'));
    final bandText = describeInstallTotal(band, StoreKind.googlePlay);
    expect(bandText, contains('at least 10,000'));
    expect(bandText, contains('reports bucket'));
  });
}
