import 'dart:io';

/// State of a cloud photo-to-3D job.
enum ReconstructionStatus {
  uploading,
  queued,
  processing,
  done,
  failed,
  expired,
}

class ReconstructionException implements Exception {
  ReconstructionException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Turns a set of photos taken around an object into a textured GLB model.
///
/// The app only depends on this interface, so the KIRI Engine backend can be
/// swapped for another photogrammetry provider (or your own server running
/// COLMAP/Meshroom) without touching the UI.
abstract class ReconstructionService {
  /// Fewest photos the provider accepts.
  int get minPhotos;

  /// Most photos the provider accepts in one job.
  int get maxPhotos;

  /// Uploads [photos] and returns the provider's job id.
  /// [onProgress] receives upload progress from 0 to 1.
  Future<String> submit(
    List<File> photos, {
    void Function(double progress)? onProgress,
  });

  Future<ReconstructionStatus> status(String jobId);

  /// Downloads the finished model for [jobId] as GLB into [destination].
  Future<void> downloadModel(String jobId, File destination);
}
