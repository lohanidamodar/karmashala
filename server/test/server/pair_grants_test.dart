import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

/// `pair --grants` (slice 5e): what makes a pairing a desktop client's is
/// named, never implied by "all".
void main() {
  test('"all" is a phone\'s grants: no desktop, admin or SSH questions', () {
    final all = parseCapabilities('all');
    expect(all.has(Capability.viewSessions), isTrue);
    for (final privileged in [
      Capability.desktopClient,
      Capability.serverAdmin,
      Capability.sshPrompts,
    ]) {
      expect(all.has(privileged), isFalse, reason: privileged.wire);
    }
  });

  test('desktop, admin and ssh name the desktop grants', () {
    expect(
      parseCapabilities('desktop').granted,
      {Capability.desktopClient},
    );
    expect(parseCapabilities('desktop,admin,ssh').granted, {
      Capability.desktopClient,
      Capability.serverAdmin,
      Capability.sshPrompts,
    });
    expect(
      parseCapabilities('all,desktop').has(Capability.startSession),
      isTrue,
    );
  });

  test('an unknown name is refused, listing the aliases', () {
    expect(
      () => parseCapabilities('desk'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains('desktop'), contains('admin')),
        ),
      ),
    );
  });
}
