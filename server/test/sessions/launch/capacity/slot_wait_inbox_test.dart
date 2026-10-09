import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/sessions/launch/capacity/slot_waits.dart';
import 'package:test/test.dart';

void main() {
  LaunchWaiter waiter(String id, {bool person = true}) => LaunchWaiter(
    ticketId: 't-$id',
    label: id,
    sessionId: id,
    priority: person ? LaunchPriority.interactive : LaunchPriority.background,
    place: 1,
    reason: 'full',
    enqueuedAt: DateTime.utc(2026, 10, 9),
    personStarted: person,
  );

  test('a person-started wait is filed once and retired when it is over', () {
    final raised = <String>[];
    final retired = <String>[];
    final inbox = SlotWaitInbox(
      raise: (id, _) => raised.add(id),
      retire: retired.add,
    );
    inbox.update(
      CapacitySnapshot(waiters: [waiter('a'), waiter('bg', person: false)]),
    );
    inbox.update(CapacitySnapshot(waiters: [waiter('a')]));
    expect(raised, ['a']);
    inbox.update(CapacitySnapshot.empty);
    expect(retired, ['a']);
  });
}
