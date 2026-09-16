import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:riverpod/riverpod.dart';

/// Asked before a quit starts; false keeps the app open.
typedef QuitGuard = Future<bool> Function();

/// Writes what the app holds only in memory, before the shutdown discards it.
typedef QuitFlush = FutureOr<void> Function();

/// What every flush together gets before the quit goes on without them.
const kBeforeQuitFlushBudget = Duration(milliseconds: 500);

/// The one place a feature says what it needs before the app quits: a
/// question that may cancel the quit, or a write that must land first.
class BeforeQuitHooks {
  BeforeQuitHooks({
    AppLogger? logger,
    this.flushBudget = kBeforeQuitFlushBudget,
  }) : _logger = logger ?? AppLogger.named('lifecycle');

  final AppLogger _logger;
  final Duration flushBudget;
  final List<({String name, QuitGuard guard})> _guards = [];
  final List<({String name, QuitFlush flush})> _flushes = [];

  /// Registers [guard]; the returned function removes it.
  void Function() addGuard(String name, QuitGuard guard) {
    final entry = (name: name, guard: guard);
    _guards.add(entry);
    return () => _guards.remove(entry);
  }

  /// Registers [flush]; the returned function removes it.
  void Function() addFlush(String name, QuitFlush flush) {
    final entry = (name: name, flush: flush);
    _flushes.add(entry);
    return () => _flushes.remove(entry);
  }

  /// Asks every guard in turn, stopping at the first that says no. A guard
  /// that throws is logged and does not hold the quit.
  Future<bool> confirm() async {
    for (final entry in List.of(_guards)) {
      try {
        if (!await entry.guard()) {
          _logger.info('before quit: ${entry.name} cancelled the quit.');
          return false;
        }
      } on Object catch (error, stack) {
        _logger.warning('before quit: ${entry.name} failed.', error, stack);
      }
    }
    return true;
  }

  /// Runs every flush together, bounded by [flushBudget]. One that is still
  /// running then is logged and left behind.
  Future<void> flush() async {
    if (_flushes.isEmpty) return;
    final pending = <String>{};
    final runs = <Future<void>>[];
    for (final entry in List.of(_flushes)) {
      pending.add(entry.name);
      runs.add(
        Future.sync(entry.flush)
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace stack) => _logger.warning(
                'before quit: ${entry.name} failed.',
                error,
                stack,
              ),
            )
            .whenComplete(() => pending.remove(entry.name)),
      );
    }
    try {
      await Future.wait(runs).timeout(flushBudget);
    } on TimeoutException {
      _logger.warning(
        'before quit: ${pending.join(', ')} did not finish within '
        '${flushBudget.inMilliseconds} ms; quitting anyway',
      );
    }
  }
}

final beforeQuitHooksProvider = Provider<BeforeQuitHooks>(
  (ref) => BeforeQuitHooks(),
);
