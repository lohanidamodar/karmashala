import 'package:karmashala/src/features/ssh/domain/remote_directory_entry.dart';
import 'package:flutter_test/flutter_test.dart';

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
