import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// The app stores as this server holds them: what the data handlers answer a
/// client with, and what the store tools answer an agent with.
abstract interface class StoreDesk {
  /// What is held now, without asking the stores.
  StoresView get view;

  /// Reads every connected store again and answers when done. With [maxAge],
  /// a view younger than that is answered as it is. A refresh already under
  /// way is joined, not doubled.
  Future<StoresView> refresh({Duration? maxAge});

  /// What reads found changed since [since], newest first; only what nobody
  /// has opened yet with [unseenOnly].
  List<StoreAppChanges> changesSince({DateTime? since, bool unseenOnly});
}

/// What answers the data protocol's `stores.*` requests; every answer but
/// [history]'s is the view as it stands after the work.
abstract interface class StoreWork {
  /// Does [request]'s work; throws [DataRefused].
  Future<StoresView> handle(StoreRequest<Object?> request);

  /// What is kept of the apps over time, as [request] asks.
  Future<StoreHistoryView> history(StoresHistoryGet request);
}
