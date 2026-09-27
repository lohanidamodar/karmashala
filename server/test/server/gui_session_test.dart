import 'package:karmashala_host/src/server/gui_session.dart';
import 'package:test/test.dart';

void main() {
  test('a Linux box with no display is headless', () {
    expect(hasGuiSession(const {}, operatingSystem: 'linux'), isFalse);
    expect(
      hasGuiSession(const {'DISPLAY': ' '}, operatingSystem: 'linux'),
      isFalse,
    );
  });

  test('X11 or Wayland is a desktop', () {
    expect(
      hasGuiSession(const {'DISPLAY': ':0'}, operatingSystem: 'linux'),
      isTrue,
    );
    expect(
      hasGuiSession(const {
        'WAYLAND_DISPLAY': 'wayland-0',
      }, operatingSystem: 'linux'),
      isTrue,
    );
  });

  test('macOS and Windows are taken to have one', () {
    expect(hasGuiSession(const {}, operatingSystem: 'macos'), isTrue);
    expect(hasGuiSession(const {}, operatingSystem: 'windows'), isTrue);
  });

  test('the variable overrides either way', () {
    expect(
      hasGuiSession(const {kHeadlessVariable: '1'}, operatingSystem: 'macos'),
      isFalse,
    );
    expect(
      hasGuiSession(const {kHeadlessVariable: '0'}, operatingSystem: 'linux'),
      isTrue,
    );
  });
}
