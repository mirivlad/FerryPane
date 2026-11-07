import 'dart:async';

/// Cumulative window acknowledgement counter.
/// Responses arriving before the caller starts waiting are retained.
class FlowAcknowledgements {
  String? _transferId;
  int _confirmed = 0;
  int _awaiting = 0;
  Completer<void>? _waiting;

  void begin(String transferId) {
    if (_waiting != null) {
      throw StateError('Previous transfer is still waiting for acknowledgement');
    }
    _transferId = transferId;
    _confirmed = 0;
    _awaiting = 0;
  }

  void accept(String transferId, int confirmedChunks) {
    if (transferId != _transferId || confirmedChunks <= _confirmed) return;
    _confirmed = confirmedChunks;
    final pending = _waiting;
    if (pending != null && !pending.isCompleted && _confirmed >= _awaiting) {
      _waiting = null;
      pending.complete();
    }
  }

  Future<void> waitFor(String transferId, int count) async {
    if (_transferId != transferId) {
      throw StateError('Acknowledgement for a different transfer');
    }
    if (_confirmed >= count) return;
    if (_waiting != null) throw StateError('Already waiting for another window');
    final pending = Completer<void>();
    _waiting = pending;
    _awaiting = count;
    try {
      await pending.future.timeout(const Duration(seconds: 45));
    } finally {
      if (_waiting == pending) _waiting = null;
    }
  }

  void cancel(Object reason) {
    _transferId = null;
    final pending = _waiting;
    _waiting = null;
    if (pending != null && !pending.isCompleted) pending.completeError(reason);
  }

  void finish() {
    _transferId = null;
  }
}
