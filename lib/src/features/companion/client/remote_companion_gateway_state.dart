part of 'remote_companion_gateway.dart';

// The two cells the gateway keeps its state in: a value plus its changes,
// and one session's transcript as this phone has assembled it.

/// A current value plus its changes. Streams emit the value on listen, then
/// every set — the seeding the gateway contract asks for.
class _Watched<T> {
  _Watched(this._value, {this.onSet});

  T _value;
  final _changes = StreamController<T>.broadcast(sync: true);

  /// Run after every set, changed or not — deduping is the caller's job.
  final void Function()? onSet;

  T get value => _value;

  set value(T next) {
    _value = next;
    _changes.add(next);
    onSet?.call();
  }

  Stream<T> get stream async* {
    yield _value;
    yield* _changes.stream;
  }
}

/// One session's transcript as this phone has assembled it so far.
class _TranscriptState {
  final listeners = <MultiStreamController<List<CompanionChatMessage>>>{};
  List<CompanionChatMessage> messages = const [];
  int cursor = 0;
  bool loaded = false;

  /// True once a re-dial invalidated [cursor]: what is held still shows, but
  /// appends must wait for a full re-read.
  bool stale = false;
}
