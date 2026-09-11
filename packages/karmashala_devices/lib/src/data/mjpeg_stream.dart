import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Splits a `multipart/x-mixed-replace` body into the JPEG frames inside it,
/// because **libmpv cannot read this stream**: media_kit's reduced ffmpeg has no
/// `mpjpeg` demuxer, so the pane got a black rectangle. No player is needed —
/// the frames are complete JPEGs and Flutter decodes those natively.
class MjpegStream {
  /// Frames from [url], until the subscription is cancelled.
  ///
  /// Each event is one complete JPEG, ready for `decodeImageFromList`.
  static Stream<Uint8List> connect(
    Uri url, {
    HttpClient Function()? httpClient,
  }) {
    late StreamController<Uint8List> frames;
    HttpClient? client;
    StreamSubscription<List<int>>? body;

    Future<void> open() async {
      try {
        client = (httpClient ?? HttpClient.new)();
        // No timeout on the response: this body never ends by design.
        final response = await (await client!.getUrl(url)).close();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException(
            'The picture server answered ${response.statusCode}',
            uri: url,
          );
        }
        final parser = _MultipartJpegParser();
        body = response.listen(
          (chunk) {
            for (final frame in parser.add(chunk)) {
              if (!frames.isClosed) frames.add(frame);
            }
          },
          onError: (Object error) {
            if (!frames.isClosed) frames.addError(error);
          },
          onDone: () {
            if (!frames.isClosed) frames.close();
          },
          cancelOnError: true,
        );
      } on Object catch (error) {
        if (!frames.isClosed) {
          frames.addError(error);
          await frames.close();
        }
      }
    }

    Future<void> close() async {
      await body?.cancel();
      body = null;
      client?.close(force: true);
      client = null;
    }

    frames = StreamController<Uint8List>(
      onListen: () => unawaited(open()),
      onCancel: close,
    );
    return frames.stream;
  }
}

/// Pulls complete JPEGs out of a multipart body arriving in arbitrary chunks.
/// Driven by the part's `Content-Length` rather than by scanning for the
/// boundary, which could also occur inside the JPEG; a part without one falls
/// back to scanning for the end marker.
class _MultipartJpegParser {
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  /// The most a part's headers may run to before the stream is treated as
  /// something other than multipart. A real part header is under 200 bytes.
  static const int _maxHeaderBytes = 8 * 1024;

  /// The most one frame may run to. A declared length past it, or a body that
  /// never finds its end marker, is dropped rather than buffered without bound.
  static const int maxFrameBytes = 32 * 1024 * 1024;

  static final List<int> _headerEnd = [13, 10, 13, 10]; // CRLF CRLF
  static const int _jpegSoi = 0xD8;
  static const int _jpegEoi = 0xD9;

  List<Uint8List> add(List<int> chunk) {
    _buffer.add(chunk);
    var bytes = _buffer.takeBytes();
    final frames = <Uint8List>[];

    while (true) {
      // WebDriverAgent writes CRLF CRLF *after* each frame as well as after the
      // part headers, so searching straight for the header terminator finds that
      // trailing pair at offset zero — and every frame after the first then
      // begins with the boundary line rather than a JPEG header.
      var lead = 0;
      while (lead < bytes.length &&
          (bytes[lead] == 13 || bytes[lead] == 10)) {
        lead++;
      }
      if (lead > 0) bytes = Uint8List.sublistView(bytes, lead);

      final headerEnd = _indexOf(bytes, _headerEnd);
      if (headerEnd < 0) {
        if (bytes.length > _maxHeaderBytes && _indexOfSoi(bytes) < 0) {
          // Not a multipart body at all, and not going to become one.
          bytes = Uint8List(0);
        }
        break;
      }
      final headers = String.fromCharCodes(bytes.sublist(0, headerEnd));
      final start = headerEnd + _headerEnd.length;
      final declared = _contentLength(headers);
      // A negative or absurd length is not one; fall back to the end marker.
      final length = declared == null || declared < 0 || declared > maxFrameBytes
          ? null
          : declared;

      final int end;
      if (length != null) {
        end = start + length;
        if (bytes.length < end) break;
      } else {
        final marker = _indexOfEoi(bytes, start);
        if (marker < 0) {
          if (bytes.length - start > maxFrameBytes) bytes = Uint8List(0);
          break;
        }
        end = marker;
      }
      frames.add(Uint8List.sublistView(bytes, start, end));
      bytes = Uint8List.sublistView(bytes, end);
    }

    _buffer.add(bytes);
    return frames;
  }

  static int? _contentLength(String headers) {
    for (final line in headers.split('\r\n')) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      if (line.substring(0, colon).trim().toLowerCase() != 'content-length') {
        continue;
      }
      return int.tryParse(line.substring(colon + 1).trim());
    }
    return null;
  }

  static int _indexOf(Uint8List haystack, List<int> needle) {
    outer:
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static int _indexOfSoi(Uint8List bytes) {
    for (var i = 0; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0xFF && bytes[i + 1] == _jpegSoi) return i;
    }
    return -1;
  }

  /// One past the JPEG end marker at or after [from].
  static int _indexOfEoi(Uint8List bytes, int from) {
    for (var i = from; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0xFF && bytes[i + 1] == _jpegEoi) return i + 2;
    }
    return -1;
  }
}
