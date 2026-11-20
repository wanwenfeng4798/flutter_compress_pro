import 'package:flutter_compress_pro/src/desktop/ffmpeg_video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FfmpegVideo.parseRotation', () {
    test('no rotation metadata is 0', () {
      expect(FfmpegVideo.parseRotation({'codec_type': 'video'}), 0);
    });

    test(
      'displaymatrix side data is counter-clockwise, reported clockwise',
      () {
        int rot(num r) => FfmpegVideo.parseRotation({
          'side_data_list': [
            {'side_data_type': 'Display Matrix', 'rotation': r},
          ],
        });
        expect(rot(-90), 90);
        expect(rot(90), 270);
        expect(rot(180), 180);
        expect(rot(-180), 180);
        expect(rot(0), 0);
      },
    );

    test('legacy rotate tag is clockwise and may be a string', () {
      int rot(Object r) => FfmpegVideo.parseRotation({
        'tags': {'rotate': r},
      });
      expect(rot('90'), 90);
      expect(rot('270'), 270);
      expect(rot(-90), 270);
    });

    test('side data wins over the legacy tag', () {
      expect(
        FfmpegVideo.parseRotation({
          'tags': {'rotate': '90'},
          'side_data_list': [
            {'rotation': 0},
          ],
        }),
        0,
      );
    });
  });
}
