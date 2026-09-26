/// The client/server data API: typed requests per domain (notes, todos,
/// preferences), the change batches a server pushes, typed refusals, and the
/// JSON envelope that carries them over any transport.
library;

export 'src/data_change.dart';
export 'src/data_endpoint.dart';
export 'src/data_envelope.dart';
export 'src/data_request.dart';
export 'src/preference_keys.dart';
export 'src/refusal.dart';
