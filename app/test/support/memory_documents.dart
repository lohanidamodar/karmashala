import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/features/files/data/files_client.dart';

/// A [FilesClient] with no server behind it — what an in-memory
/// `DocumentStore` a test overrides `load`/`stamp`/`write` of hands its
/// super constructor, since it never reaches for the server's files.
FilesClient noServerFiles() =>
    FilesClient(DataClient.unavailable('an in-memory document store'));
