import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/ui/image_cache_limit.dart';

void main() {
  test('the image cache is held to 32 MB and 100 pictures', () {
    final cache = ImageCache();
    // Flutter's own ceiling, which is what the app ran with.
    expect(cache.maximumSizeBytes, 100 << 20);
    capImageCache(cache);
    expect(cache.maximumSizeBytes, imageCacheBytes);
    expect(cache.maximumSize, imageCacheCount);
    expect(imageCacheBytes, 32 * 1024 * 1024);
  });
}
