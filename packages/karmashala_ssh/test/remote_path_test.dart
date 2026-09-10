import 'package:karmashala_ssh/files.dart';
import 'package:test/test.dart';

void main() {
  group('joinRemotePath', () {
    test('joins with a POSIX separator regardless of the host platform', () {
      expect(joinRemotePath('/home/me', 'src'), '/home/me/src');
    });

    test('does not double the separator', () {
      expect(joinRemotePath('/home/me/', 'src'), '/home/me/src');
    });

    test('handles the filesystem root', () {
      expect(joinRemotePath('/', 'etc'), '/etc');
      expect(joinRemotePath('', 'etc'), '/etc');
    });
  });
}
