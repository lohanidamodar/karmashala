import 'dart:async';
import 'dart:io';

/// Opens the byte stream one viewer will be served. Called once per connection:
/// a muxer's continuity counters and timestamp base belong to one output stream.
typedef MediaStreamFactory = Stream<List<int>> Function();

/// Serves a live byte stream to a local video player over loopback HTTP, because
/// libmpv cannot open a raw elementary stream and a local URL is the one input
/// every video player accepts. Loopback only: what it serves is the user's
/// screen.
///
/// **A viewer that vanishes is not detected here, and cannot be** — writes to a
/// destroyed peer socket report success and `response.done` never completes — so
/// whoever started the stream is what stops it.
class LoopbackMediaServer {
  LoopbackMediaServer._(this._server, this.url, this._viewers);

  /// Binds loopback and serves [openStream] to every viewer that connects.
  ///
  /// [contentType] is what the player is told it is reading; libmpv picks its
  /// demuxer from it. [onChunkWritten] fires after each chunk reaches the
  /// socket, for callers measuring how far behind the picture is.
  static Future<LoopbackMediaServer> serve({
    required MediaStreamFactory openStream,
    ContentType? contentType,
    String path = 'live.ts',
    void Function()? onChunkWritten,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = Uri.parse('http://127.0.0.1:${server.port}/$path');
    final viewers = <StreamSubscription<List<int>>>{};
    server.listen((request) async {
      final response = request.response
        // Every chunk is a frame the viewer is waiting for; buffering them is
        // latency with no upside.
        ..bufferOutput = false
        ..headers.contentType = contentType ?? ContentType('video', 'mp2t');

      // A producer that ends must close the response, or the player waits on a
      // chunked body that never gets its last chunk. The close waits for the
      // last flush, or it truncates bytes still on their way to the socket.
      var pending = Future<void>.value();
      var finished = false;
      Future<void> finish() async {
        if (finished) return;
        finished = true;
        await pending;
        try {
          await response.close();
        } on Object {
          // Already gone.
        }
      }

      final subscription = openStream().listen(
        (chunk) {
          // Writes are chained rather than issued from here: a second `flush()`
          // raised while the first is in flight throws, silently dropping that
          // frame and every one behind it. The chain is not awaited by the
          // listener, so a slow socket cannot stall a live picture's producer.
          pending = pending
              .then((_) async {
                response.add(chunk);
                // **After** the flush, not before it: `add` only buffers, so
                // reporting here would call a chunk delivered that a stalled or
                // dead viewer has not taken.
                await response.flush();
                onChunkWritten?.call();
              })
              .catchError((Object _) {
                // The viewer went away mid-write. `response.done` below is what
                // actually ends this subscription.
              });
        },
        onDone: () => unawaited(finish()),
        // The producer failing ends this viewer's stream, not the server: the
        // next viewer gets a fresh one.
        onError: (Object _) => unawaited(finish()),
      );
      viewers.add(subscription);
      await response.done.catchError((Object _) {});
      viewers.remove(subscription);
      await subscription.cancel();
    }, onError: (Object _) {});
    return LoopbackMediaServer._(server, url, viewers);
  }

  final HttpServer _server;

  /// Every producer currently feeding a viewer. Tracked because
  /// `response.done` cannot be relied on to fire (see the class doc), so
  /// [close] is what actually ends them.
  final Set<StreamSubscription<List<int>>> _viewers;

  /// What the video player opens.
  final Uri url;

  /// The port bound, for a caller that wants to name it in a log.
  int get port => _server.port;

  /// Stops serving and ends every producer. Not a formality: since a vanished
  /// viewer is never noticed, this is the only thing that stops the encoding.
  Future<void> close() async {
    final viewers = _viewers.toList();
    _viewers.clear();
    for (final viewer in viewers) {
      await viewer.cancel();
    }
    await _server.close(force: true);
  }
}
