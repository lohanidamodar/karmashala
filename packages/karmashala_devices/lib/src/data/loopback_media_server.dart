import 'dart:async';
import 'dart:io';

/// Opens the byte stream one viewer will be served.
///
/// Called once per connection, not once per server: a live stream has
/// per-viewer state — an MPEG-TS muxer's continuity counters and timestamp
/// base belong to one output stream, and replaying the same packets to a second
/// viewer would duplicate them.
typedef MediaStreamFactory = Stream<List<int>> Function();

/// Serves a live byte stream to a local video player over loopback HTTP.
///
/// The indirection exists because libmpv cannot open a raw elementary stream,
/// and because a local URL is the one input every video player accepts. It is
/// deliberately ignorant of what the bytes are: the Android live view feeds it
/// MPEG-TS muxed from scrcpy's H.264, and anything else that can produce a
/// container libmpv reads can use the same door.
///
/// Loopback only, on an ephemeral port. What it serves is the user's screen;
/// binding anywhere else would put that on the network.
///
/// ## The viewer's lifetime is the caller's to end, not this server's
///
/// A viewer that vanishes is **not** detected here, and cannot be. Measured on
/// macOS against a peer socket that had been destroyed: sixty 64 KiB writes to
/// the `HttpResponse` all reported success, and `response.done` never
/// completed. There is no failed write to learn from, so a producer is not
/// stopped by the picture going away — whoever started the stream stops it.
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

      // A live view's producer normally never ends — the device keeps
      // encoding until the pane is closed — but one that does end must close
      // the response, or the player sits waiting on a chunked body that will
      // never have a last chunk.
      //
      // The close has to wait for the last flush. Flushes are deliberately not
      // awaited per chunk (see below), so at the moment the producer finishes
      // there may still be bytes on their way to the socket, and closing over
      // the top of them truncates the stream.
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
          // Writes are chained rather than issued straight from here. An
          // `HttpResponse` is an `IOSink`, and a second `flush()` raised while
          // the first is still in flight throws — which, caught, silently drops
          // that frame and every frame behind it. The chain also keeps the
          // bytes in the order the producer emitted them.
          //
          // The chain is not awaited by the listener, so a slow socket does not
          // stall the producer of a live picture; [finish] is what waits for
          // the tail before closing.
          pending = pending
              .then((_) async {
                response.add(chunk);
                // **After** the flush, not before it. `add` only buffers, so
                // reporting there says a chunk was handed over when a stalled
                // or dead viewer has taken nothing — and the live view reads
                // this as "the picture is being updated". A viewer that has
                // stopped consuming is exactly what it must be able to say.
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

  /// Stops serving and ends every producer.
  ///
  /// Cancelling the producers is not a formality: since a vanished viewer is
  /// never noticed, this is the only thing that tells a device it can stop
  /// encoding.
  Future<void> close() async {
    final viewers = _viewers.toList();
    _viewers.clear();
    for (final viewer in viewers) {
      await viewer.cancel();
    }
    await _server.close(force: true);
  }
}
