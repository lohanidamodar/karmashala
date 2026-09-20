import 'package:test/test.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

const String _address = 'http://127.0.0.1:53119/bt32nsO63q8=/';
const String _expected = 'ws://127.0.0.1:53119/bt32nsO63q8=/ws';

void main() {
  test('the whole announcement on one row', () {
    expect(
      vmServiceUriInPaneRows([
        'Launching lib/main.dart on sdk gphone64 x86 64 in debug mode...',
        'A Dart VM Service on sdk gphone64 x86 64 is available at: $_address',
      ])?.toString(),
      _expected,
    );
  });

  test(
    'wrapped at the space before the address, which is what a pane does',
    () {
      // Wrapping backs up to the last whitespace, so the address starts a row.
      expect(
        vmServiceUriInPaneRows([
          'A Dart VM Service on sdk gphone64 x86 64 is available at:',
          _address,
        ])?.toString(),
        _expected,
      );
    },
  );

  test('the sentence itself wrapped as well, in a narrow pane', () {
    expect(
      vmServiceUriInPaneRows([
        'A Dart VM Service on sdk',
        'gphone64 x86 64 is available',
        'at: $_address',
      ])?.toString(),
      _expected,
    );
  });

  test('the DevTools line is not the address, even though it contains it', () {
    expect(
      vmServiceUriInPaneRows([
        'The Flutter DevTools debugger and profiler on sdk gphone64 x86 64 is '
            'available at: http://127.0.0.1:9101?uri=$_address',
      ]),
      isNull,
    );
  });

  test('DevTools printed after the announcement does not overwrite it', () {
    final uri = vmServiceUriInPaneRows([
      'A Dart VM Service on macOS is available at: $_address',
      'The Flutter DevTools debugger and profiler on macOS is available at: '
          'http://127.0.0.1:9101?uri=$_address',
    ]);
    expect(uri?.port, 53119);
  });

  test('measured 2026-09-09: DevTools shares the VM service host AND port', () {
    // Copied verbatim out of a real `flutter run -d windows`: "the first URL
    // after the word available" would have connected to the DevTools server.
    expect(
      vmServiceUriInPaneRows([
        'A Dart VM Service on Windows is available at: '
            'http://127.0.0.1:63866/n_1Ulc_Fksw=/',
        'The Flutter DevTools debugger and profiler on Windows is available '
            'at: http://127.0.0.1:63866/n_1Ulc_Fksw=/devtools/'
            '?uri=ws://127.0.0.1:63866/n_1Ulc_Fksw=/ws',
      ])?.toString(),
      // …and this is exactly what --vmservice-out-file wrote in that same run.
      'ws://127.0.0.1:63866/n_1Ulc_Fksw=/ws',
    );
  });

  test('the DevTools line on its own is still not the address', () {
    expect(
      vmServiceUriInPaneRows([
        'The Flutter DevTools debugger and profiler on Windows is available '
            'at: http://127.0.0.1:63866/n_1Ulc_Fksw=/devtools/'
            '?uri=ws://127.0.0.1:63866/n_1Ulc_Fksw=/ws',
      ]),
      isNull,
    );
  });

  test('a pane that has not announced anything answers null, not a guess', () {
    expect(
      vmServiceUriInPaneRows([
        'Running Gradle task \'assembleDebug\'...',
        'Installing build/app/outputs/flutter-apk/app-debug.apk...',
      ]),
      isNull,
    );
  });

  test('an empty pane is null', () {
    expect(vmServiceUriInPaneRows(const []), isNull);
  });

  test('the ws:// spelling of the same address is taken too', () {
    expect(
      vmServiceUriInPaneRows([
        'A Dart VM Service on Windows is available at: '
            'ws://127.0.0.1:53119/bt32nsO63q8=/ws',
      ])?.toString(),
      _expected,
    );
  });

  test('a portless URL in the log is not treated as an address', () {
    expect(
      vmServiceUriInPaneRows([
        'A Dart VM Service on Windows is available at:',
        'https://flutter.dev/docs',
      ]),
      isNull,
    );
  });

  test('the address more than two rows below is not claimed', () {
    expect(
      vmServiceUriInPaneRows([
        'A Dart VM Service on Windows is available at:',
        '',
        '',
        _address,
      ]),
      isNull,
    );
  });

  test('the first announcement wins when two devices are running', () {
    final uri = vmServiceUriInPaneRows([
      'A Dart VM Service on macOS is available at: $_address',
      'A Dart VM Service on Chrome is available at: '
          'http://127.0.0.1:60000/Zzz=/',
    ]);
    expect(uri?.port, 53119);
  });
}
