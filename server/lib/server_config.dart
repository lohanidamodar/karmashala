/// The server's data directory and its `server.json`, for a client on the
/// same machine that has no server to ask: the desktop app opens its store
/// there, and reads and writes the file itself only while no server runs.
library;

export 'src/server/server_config.dart';
export 'src/server/server_data_directory.dart';
