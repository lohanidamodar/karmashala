/// One machine's files behind the verbs a file pane, an editor and Quick Open
/// need (slice 3c): the values clients carry ([FileEntry], [FileStamp],
/// [FileStat], [WriteExpectation], [RepoFiles]) and the spaces the server
/// runs — this machine's disk and a WSL distribution ([LocalFileSpace]), an
/// SSH host over SFTP ([SftpFileSpace]) — with the copy between two of them
/// ([FileTransfer]) and Quick Open's bounded walk ([RepoFileIndex]).
library;

export 'src/file_space.dart';
export 'src/file_transfer.dart';
export 'src/file_values.dart';
export 'src/local_file_space.dart';
export 'src/repo_file_index.dart';
export 'src/sftp_file_space.dart';
