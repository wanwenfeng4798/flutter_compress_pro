# Third-party notices

These files are vendored into `assets/` and ship inside the **web** build output
of any app that uses this plugin. They are loaded lazily — only when video
compression is first used on web — so an app that never compresses video on web
never downloads them. Image compression on web needs neither.

MP4Box 2.4.1 is bundled from the upstream ES module using esbuild 0.28.2
(`--bundle --format=iife --global-name=MP4Box --minify`). A compatibility footer
exposes `DataStream = MP4Box.DataStream` and maps `DataStream.BIG_ENDIAN` to
`MP4Box.Endianness.BIG_ENDIAN`. Its upstream source is otherwise unchanged.
mp4-muxer 5.2.2 is shipped unmodified from the upstream browser build.

| File | Version | Upstream | Licence |
|---|---|---|---|
| `mp4box.all.min.js` | 2.4.1 | [gpac/mp4box.js](https://github.com/gpac/mp4box.js) | BSD-3-Clause |
| `mp4-muxer.js` | 5.2.2 | [Vanilagy/mp4-muxer](https://github.com/Vanilagy/mp4-muxer) | MIT |

`flutter_compress_pro_web.js` (20 KB) is this plugin's own code and is covered by the
plugin's MIT licence.

## What this means for you

Neither licence restricts commercial or closed-source use of your app, and
neither is triggered by merely calling into these files. Both do require that
the licence notice travel with the copy — which is what this file is for.

The licence identifiers above are taken from the exact published package
versions, including mp4-muxer 5.2.2 (MIT).

Upstream licence texts are included alongside the bundles as
`MP4BOX-LICENSE.txt` and `MP4-MUXER-LICENSE.txt`.

mp4-muxer is deprecated upstream in favour of Mediabunny. Migrating the engine
is a separate code change; 5.2.2 remains its latest published version.
