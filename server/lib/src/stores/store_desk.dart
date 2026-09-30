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
}

/// What answers the data protocol's `stores.*` requests; every answer is the
/// view as it stands after the work.
abstract interface class StoreWork {
  /// Does [request]'s work; throws [DataRefused].
  Future<StoresView> handle(StoreRequest<Object?> request);
}
