import 'package:ferrypane/core/flow_acknowledgements.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('early acknowledgement is remembered, not lost', () async {
    final acks = FlowAcknowledgements()..begin('tx-one');
    acks.accept('tx-one', 8);
    await acks.waitFor('tx-one', 8).timeout(const Duration(milliseconds: 300));
  });

  test('out-of-order, duplicate and wrong-transfer acknowledgements ignored', () async {
    final acks = FlowAcknowledgements()..begin('tx-two');
    acks.accept('old-transfer', 99);
    acks.accept('tx-two', 4);
    var resolved = false;
    final pending = acks.waitFor('tx-two', 8).then((_) => resolved = true);
    acks.accept('tx-two', 4);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(resolved, isFalse);
    acks.accept('tx-two', 8);
    await pending;
    expect(resolved, isTrue);
  });

  test('each transfer starts with its own acknowledgement counter', () async {
    final acks = FlowAcknowledgements()..begin('tx-a');
    acks.accept('tx-a', 8);
    await acks.waitFor('tx-a', 8);
    acks.finish();
    acks.begin('tx-b');
    var finished = false;
    final pending = acks.waitFor('tx-b', 8).then((_) => finished = true);
    acks.accept('tx-a', 16);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(finished, isFalse);
    acks.accept('tx-b', 8);
    await pending;
  });
}
