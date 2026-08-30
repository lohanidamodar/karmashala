import 'dart:async';

import 'package:chitragupta/src/features/ssh/data/channel_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lets work through up to the limit', () async {
    final limiter = ChannelLimiter(3);
    final gates = List.generate(3, (_) => Completer<void>());
    for (final gate in gates) {
      unawaited(limiter.withSlot(() => gate.future));
    }
    await Future<void>.delayed(Duration.zero);
    expect(limiter.inUse, 3);
    expect(limiter.waiting, 0);
    for (final gate in gates) {
      gate.complete();
    }
  });

  test('queues the overflow instead of failing it', () async {
    final limiter = ChannelLimiter(2);
    final held = [Completer<void>(), Completer<void>()];
    for (final gate in held) {
      unawaited(limiter.withSlot(() => gate.future));
    }
    await Future<void>.delayed(Duration.zero);

    var thirdRan = false;
    final third = limiter.withSlot(() async => thirdRan = true);
    await Future<void>.delayed(Duration.zero);
    expect(thirdRan, isFalse, reason: 'no slot is free yet');
    expect(limiter.waiting, 1);

    held.first.complete();
    await third;
    expect(thirdRan, isTrue);
    held.last.complete();
  });

  test('a slot is released even when the work throws', () async {
    final limiter = ChannelLimiter(1);
    await expectLater(
      limiter.withSlot(() async => throw StateError('boom')),
      throwsStateError,
    );
    expect(limiter.inUse, 0);
    expect(await limiter.withSlot(() async => 'next'), 'next');
  });

  test('order is preserved for queued work', () async {
    final limiter = ChannelLimiter(1);
    final order = <int>[];
    final blocker = Completer<void>();
    unawaited(limiter.withSlot(() => blocker.future));
    await Future<void>.delayed(Duration.zero);

    final queued = [
      for (var i = 0; i < 3; i++) limiter.withSlot(() async => order.add(i)),
    ];
    blocker.complete();
    await Future.wait(queued);
    expect(order, [0, 1, 2]);
  });
}
