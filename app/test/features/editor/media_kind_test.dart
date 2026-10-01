import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/domain/media_kind.dart';

void main() {
  group('mediaKindOf', () {
    test('maps each image extension to an image', () {
      for (final ext in ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico']) {
        expect(mediaKindOf('/repo/a.$ext'), MediaKind.image, reason: ext);
      }
    });

    test('maps each video extension to a video', () {
      for (final ext in ['mp4', 'webm', 'mov', 'mkv']) {
        expect(mediaKindOf('/repo/a.$ext'), MediaKind.video, reason: ext);
      }
    });

    test('maps each audio extension to audio', () {
      for (final ext in ['mp3', 'wav', 'ogg', 'm4a', 'flac']) {
        expect(mediaKindOf('/repo/a.$ext'), MediaKind.audio, reason: ext);
      }
    });

    test('ignores the case of the extension', () {
      expect(mediaKindOf('/repo/Shot.PNG'), MediaKind.image);
      expect(mediaKindOf('/repo/clip.Mp4'), MediaKind.video);
      expect(mediaKindOf('/repo/song.FLAC'), MediaKind.audio);
    });

    test('reads a Windows path by its own name', () {
      expect(mediaKindOf(r'C:\repo\assets\Logo.JPG'), MediaKind.image);
      expect(mediaKindOf(r'C:\repo.png\notes'), isNull);
    });

    test('leaves SVG to the text editor', () {
      expect(mediaKindOf('/repo/icon.svg'), isNull);
      expect(mediaKindOf('/repo/icon.SVG'), isNull);
    });

    test('a file with no extension, or a bare dot, is not media', () {
      expect(mediaKindOf('/repo/README'), isNull);
      expect(mediaKindOf('/repo/trailing.'), isNull);
      expect(mediaKindOf('/repo/main.dart'), isNull);
    });

    test('a dotfile is a name, not an extension', () {
      expect(mediaKindOf('/repo/.png'), isNull);
      expect(mediaKindOf('/repo/.mp4'), isNull);
    });

    test('a remote document id is read by its path', () {
      expect(mediaKindOf('env␟/path/a.PNG'), MediaKind.image);
      expect(mediaKindOf('wsl-arch␟/home/me/talk.webm'), MediaKind.video);
      expect(mediaKindOf('env␟/path/.png'), isNull);
      expect(mediaKindOf('env␟/path/notes'), isNull);
    });
  });
}
