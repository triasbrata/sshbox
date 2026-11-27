import 'package:flutter/painting.dart';

/// What decoded pictures may take in all: Flutter's own ceiling is 100 MB and
/// 1000 images, far more than chat's thumbnails, the image viewer and the
/// Markdown preview ever need at once. A picture that falls out is decoded
/// again when drawn.
const imageCacheBytes = 0;
const imageCacheCount = 100;

/// Sets the limits on [cache]. Called once in main, after the binding exists.
void capImageCache(ImageCache cache) {
  cache
    ..maximumSizeBytes = imageCacheBytes
    ..maximumSize = imageCacheCount;
}
