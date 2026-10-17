/*
 * flutter_compress_pro — Web engine (WebCodecs + mp4box.js demux + mp4-muxer mux).
 *
 * Pipeline: fetch blob -> mp4box demux -> VideoDecoder -> (canvas rescale) ->
 * VideoEncoder(target bitrate) -> mp4-muxer -> Blob(mp4) -> object URL.
 *
 * v1 transcodes VIDEO only (audio is dropped) — a documented limitation;
 * audio passthrough/re-encode is a follow-up. H.264 output (broadest support).
 *
 * Depends on globals: MP4Box, DataStream (from mp4box.all.min.js), Mp4Muxer.
 */
(function () {
  'use strict';
  // Idempotent: this file is injected by two independent lazy loaders (video and
  // image). Re-running the IIFE would rebuild the namespace and wipe OUTPUT_URLS,
  // silently turning revoke()/revokeAll() into no-ops.
  if (window.flutterCompressWeb) return;
  const NS = {};
  window.flutterCompressWeb = NS;

  const cancelled = new Set();
  /** Ids of runs currently in flight, so `cancelAll` has something to target. */
  const active = new Map();
  NS.cancel = function (id) { if (id && active.has(id)) { cancelled.add(id); active.get(id).abort(); } };
  /** Cancel every in-flight run (backs Dart's `cancel()` with no id). */
  NS.cancelAll = function () { for (const id of active.keys()) NS.cancel(id); };

  /** Every output object URL we created, so `revokeAll` can free them. */
  const OUTPUT_URLS = new Set();
  function trackUrl(url) { OUTPUT_URLS.add(url); return url; }

  /** Upper bound on waiting for mp4box to deliver every sample. */
  const DEMUX_TIMEOUT_MS = 10000;

  /**
   * Whether the source should be handed back untouched. Integer arithmetic on
   * purpose — the same expression runs in Kotlin, Swift and JS (CLAUDE.md
   * §12.2), and float division would let the three drift at the boundary.
   */
  function keepsOriginal(compressedBytes, originalBytes, keepOriginalIfLarger, minSavingsPercent) {
    if (!keepOriginalIfLarger || !(originalBytes > 0)) return false;
    const pct = minSavingsPercent || 0;
    const ceiling = originalBytes - Math.trunc((originalBytes * pct) / 100);
    return compressedBytes >= ceiling;
  }

  /** Release a WebCodecs encoder/decoder without masking the real error. */
  function closeQuietly(codec) {
    try { if (codec && codec.state !== 'closed') codec.close(); } catch (_) {}
  }

  NS.isSupported = function () {
    return typeof window.VideoEncoder === 'function' &&
      typeof window.VideoDecoder === 'function' &&
      typeof MP4Box !== 'undefined' && typeof Mp4Muxer !== 'undefined';
  };

  NS.canEncode = async function () {
    if (!NS.isSupported()) return false;
    for (const codec of ['avc1.42001e', 'avc1.4D0028', 'avc1.640028']) {
      try {
        if ((await VideoEncoder.isConfigSupported({codec, width: 16, height: 16,
          bitrate: 100000, framerate: 30})).supported) return true;
      } catch (_) {}
    }
    return false;
  };

  let prepared = null;
  let preparedTimer = null;
  async function fetchBuffer(url, signal) {
    const res = await fetch(url, { signal });
    if (!res.ok) throw new Error('fetch failed: ' + res.status);
    return await res.arrayBuffer();
  }

  function avcDescription(file, trackId) {
    const trak = file.getTrackById(trackId);
    for (const entry of trak.mdia.minf.stbl.stsd.entries) {
      const box = entry.avcC || entry.hvcC || entry.vpcC || entry.av1C;
      if (box) {
        const stream = new DataStream(undefined, 0, DataStream.BIG_ENDIAN);
        box.write(stream);
        return new Uint8Array(stream.buffer, 8); // strip box header
      }
    }
    return undefined;
  }

  // ---- info --------------------------------------------------------------

  NS.getInfo = async function (url, id) {
    const controller = new AbortController();
    if (id) active.set(id, controller);
    try {
      const buf = await fetchBuffer(url, controller.signal);
      if (id && cancelled.has(id)) throw new Error('cancelled');
      const sizeBytes = buf.byteLength;
      prepared = { url, buffer: buf };
      clearTimeout(preparedTimer);
      preparedTimer = setTimeout(() => { prepared = null; }, 30000);
      const file = MP4Box.createFile();
      let timeout;
      const info = await new Promise((resolve, reject) => {
        timeout = setTimeout(() => reject(new Error('metadata timed out')), DEMUX_TIMEOUT_MS);
        file.onError = (e) => reject(new Error('mp4box: ' + e));
        file.onReady = resolve;
        buf.fileStart = 0;
        file.appendBuffer(buf);
        file.flush();
      }).finally(() => clearTimeout(timeout));
      const video = info.videoTracks && info.videoTracks[0];
      if (!video) throw new Error('no video track');
      const durationMs = info.duration / info.timescale * 1000;
      const fps = video.nb_samples / Math.max(video.movie_duration / video.movie_timescale, 0.001);
      return {
        width: video.video ? video.video.width : video.track_width,
        height: video.video ? video.video.height : video.track_height,
        durationMs: Math.round(durationMs), sizeBytes,
        bitrateKbps: Math.round(sizeBytes * 8 / Math.max(durationMs / 1000, 0.001) / 1000),
        frameRate: isFinite(fps) ? fps : null, codec: video.codec || null,
        hasAudio: (info.audioTracks || []).length > 0, rotation: 0,
      };
    } catch (error) {
      if (id && (cancelled.has(id) || error.name === 'AbortError')) throw new Error('cancelled');
      throw error;
    } finally {
      if (id) { active.delete(id); cancelled.delete(id); }
    }
  };

  // ---- thumbnail (simple <video> + canvas) -------------------------------

  NS.thumbnail = function (url, positionMs, quality, maxWidth) {
    const video = document.createElement('video');
    let timeout;
    return new Promise((resolve, reject) => {
      timeout = setTimeout(() => reject(new Error('thumbnail timed out')), DEMUX_TIMEOUT_MS);
      video.muted = true;
      video.preload = 'auto';
      video.onloadedmetadata = () => {
        video.currentTime = Math.max(0, Math.min((positionMs || 0) / 1000, (video.duration || 0.1) - 0.01));
      };
      video.onseeked = () => {
        try {
          const scale = maxWidth && video.videoWidth > maxWidth ? maxWidth / video.videoWidth : 1;
          const canvas = document.createElement('canvas');
          canvas.width = Math.max(1, Math.round(video.videoWidth * scale));
          canvas.height = Math.max(1, Math.round(video.videoHeight * scale));
          canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
          resolve(canvas.toDataURL('image/jpeg', (quality || 80) / 100));
        } catch (error) { reject(error); }
      };
      video.onerror = () => reject(new Error('video load error'));
      video.src = url;
    }).finally(() => {
      clearTimeout(timeout);
      video.onseeked = video.onloadedmetadata = video.onerror = null;
      video.removeAttribute('src');
      video.load();
    });
  };

  // ---- compress ----------------------------------------------------------

  // cfg: { id, targetWidth, targetHeight, videoBitrateBps, frameRate,
  //        trimStartMs, trimEndMs, keepOriginalIfLarger, originalSizeBytes }
  // onProgress: (fraction:number, outBytes:number) => void
  NS.compress = async function (url, cfg, onProgress) {
    if (!NS.isSupported()) throw new Error('WebCodecs not supported in this browser');
    const id = cfg.id;
    const controller = new AbortController();
    active.set(id, controller);
    let file = null, encoder = null, decoder = null;
    try {
    if (cancelled.has(id)) throw new Error('cancelled');
    const buf = prepared && prepared.url === url ? prepared.buffer : await fetchBuffer(url, controller.signal);
    prepared = null;
    clearTimeout(preparedTimer);
    if (cancelled.has(id)) throw new Error('cancelled');
    // MP4Box 2.x discards media data by default; extraction needs it retained.
    file = MP4Box.createFile(true);

    let readyTimeout;
    const ready = new Promise((resolve, reject) => {
      readyTimeout = setTimeout(() => reject(new Error('metadata timed out')), DEMUX_TIMEOUT_MS);
      file.onError = (e) => reject(new Error('mp4box: ' + e));
      file.onReady = (info) => resolve(info);
    });
    // Annotate the fetched buffer instead of slicing a copy (see getInfo).
    buf.fileStart = 0;
    file.appendBuffer(buf);
    file.flush();
    const info = await ready.finally(() => clearTimeout(readyTimeout));
    const vTrack = info.videoTracks[0];
    if (!vTrack) throw new Error('no video track');

    const timescale = vTrack.timescale;
    const totalSamples = vTrack.nb_samples;
    const durationMs = Math.round((info.duration / info.timescale) * 1000);
    const tw = cfg.targetWidth, th = cfg.targetHeight;
    const srcW = vTrack.video ? vTrack.video.width : vTrack.track_width;
    const srcH = vTrack.video ? vTrack.video.height : vTrack.track_height;
    const needResize = tw !== srcW || th !== srcH;
    const fps = cfg.frameRate && cfg.frameRate > 0 ? cfg.frameRate : 30;
    // Source facts, reported back verbatim on the skipped path.
    const srcFps = vTrack.nb_samples > 0 && vTrack.movie_duration > 0
      ? vTrack.nb_samples / (vTrack.movie_duration / vTrack.movie_timescale)
      : null;
    const srcHasAudio = (info.audioTracks || []).length > 0;

    // Target-size mode uses constant bitrate so the output actually fills the
    // requested budget; quality mode stays variable (more efficient).
    const bitrateMode = cfg.bitrateMode || 'variable';

    // Pick a supported encoder config: HEVC (H.265) first when requested, with
    // automatic fallback to H.264 where the browser can't encode HEVC — the
    // same policy as the Android/iOS engines.
    let encoderConfig = null, muxerCodec = 'avc', usedCodec = 'h264';
    if (cfg.codec === 'h265') {
      for (const codec of ['hev1.1.6.L93.B0', 'hvc1.1.6.L93.B0']) {
        const c = {
          codec, width: tw, height: th, bitrate: cfg.videoBitrateBps,
          framerate: Math.round(fps), hevc: { format: 'hevc' }, bitrateMode,
        };
        try {
          const sup = await VideoEncoder.isConfigSupported(c);
          if (sup && sup.supported) {
            encoderConfig = c; muxerCodec = 'hevc'; usedCodec = 'h265'; break;
          }
        } catch (_) {}
      }
    }
    if (!encoderConfig) {
      for (const codec of ['avc1.640028', 'avc1.4D0028', 'avc1.42E01E']) {
        const c = {
          codec, width: tw, height: th, bitrate: cfg.videoBitrateBps,
          framerate: Math.round(fps), avc: { format: 'avc' }, bitrateMode,
        };
        try {
          const sup = await VideoEncoder.isConfigSupported(c);
          if (sup && sup.supported) {
            encoderConfig = c; muxerCodec = 'avc'; usedCodec = 'h264'; break;
          }
        } catch (_) {}
      }
    }
    if (!encoderConfig) throw new Error('no supported H.264/H.265 encoder config');

    // Muxer — codec must match what the encoder actually produced.
    const muxer = new Mp4Muxer.Muxer({
      target: new Mp4Muxer.ArrayBufferTarget(),
      video: { codec: muxerCodec, width: tw, height: th },
      fastStart: 'in-memory',
      // Real videos' first frame rarely has DTS/CTS 0 (container offsets);
      // shift all timestamps so the first is zero, as mp4-muxer requires.
      firstTimestampBehavior: 'offset',
    });

    let encodeError = null;
    encoder = new VideoEncoder({
      output: (chunk, meta) => muxer.addVideoChunk(chunk, meta),
      error: (e) => { encodeError = e; },
    });
    encoder.configure(encoderConfig);

    // Rescale canvas (only if needed)
    let canvas = null, ctx = null;
    if (needResize) {
      canvas = document.createElement('canvas');
      canvas.width = tw; canvas.height = th;
      ctx = canvas.getContext('2d');
    }

    let processed = 0;
    const keyInterval = Math.max(1, Math.round(fps * 2));
    let frameIndex = 0;
    /// Frames the encoder actually accepted — the basis for the real output
    /// duration, so a truncated encode can't be reported as full length.
    let encodedFrames = 0;
    let encodedStart = Infinity, encodedEnd = -Infinity;

    decoder = new VideoDecoder({
      output: (frame) => {
        if (cancelled.has(id)) { frame.close(); return; }
        let toEncode = frame;
        if (needResize) {
          ctx.drawImage(frame, 0, 0, tw, th);
          toEncode = new VideoFrame(canvas, {
            timestamp: frame.timestamp, duration: frame.duration || undefined,
          });
          frame.close();
        }
        const keyFrame = (frameIndex % keyInterval) === 0;
        frameIndex++;
        try {
          encoder.encode(toEncode, { keyFrame });
          encodedStart = Math.min(encodedStart, toEncode.timestamp);
          encodedEnd = Math.max(encodedEnd, toEncode.timestamp + (toEncode.duration || 1e6 / (srcFps || fps)));
        } catch (error) { encodeError = error; }
        finally { toEncode.close(); }
        encodedFrames++;
        processed++;
        if (onProgress && (processed % 5 === 0)) {
          onProgress(Math.min(processed / totalSamples, 0.99), 0);
        }
      },
      error: (e) => { encodeError = e; },
    });

    const desc = avcDescription(file, vTrack.id);
    decoder.configure({
      codec: vTrack.codec,
      description: desc,
      codedWidth: srcW,
      codedHeight: srcH,
    });

    // Pause extraction after each batch. Decode and encode it before requesting
    // more, bounding both hardware queues and retained sample data.
    let fed = 0, batch = null;
    file.onSamples = (trackId, user, samples) => { batch = samples; file.stop(); };
    file.setExtractionOptions(vTrack.id, null, { nbSamples: 8 });
    while (fed < totalSamples) {
      if (cancelled.has(id)) throw new Error('cancelled');
      if (encodeError) throw encodeError;
      batch = null;
      file.start();
      const deadline = Date.now() + DEMUX_TIMEOUT_MS;
      while (!batch && Date.now() < deadline && !cancelled.has(id)) {
        await new Promise((r) => setTimeout(r, 5));
      }
      if (cancelled.has(id)) throw new Error('cancelled');
      if (!batch || !batch.length) throw new Error('demux timed out');
      for (const sample of batch) {
        if (cancelled.has(id)) throw new Error('cancelled');
        while (decoder.decodeQueueSize >= 8 || encoder.encodeQueueSize >= 8) {
          if (encodeError) throw encodeError;
          if (cancelled.has(id)) throw new Error('cancelled');
          await new Promise((r) => setTimeout(r, 0));
        }
        decoder.decode(new EncodedVideoChunk({
          type: sample.is_sync ? 'key' : 'delta',
          timestamp: sample.cts * 1e6 / timescale,
          duration: sample.duration * 1e6 / timescale,
          data: sample.data,
        }));
        fed++;
        file.releaseUsedSamples(vTrack.id, sample.number + 1);
      }
      // Encoder output is drained too, so asynchronous decoder callbacks cannot
      // build an unbounded encoder queue.
      while (decoder.decodeQueueSize > 0) {
        if (encodeError) throw encodeError;
        if (cancelled.has(id)) throw new Error('cancelled');
        await new Promise((r) => setTimeout(r, 0));
      }
      await encoder.flush();
    }
      await decoder.flush();
      await encoder.flush();
      if (encodeError) throw encodeError;
      if (cancelled.has(id)) { cancelled.delete(id); throw new Error('cancelled'); }

      muxer.finalize();
      const blob = new Blob([muxer.target.buffer], { type: 'video/mp4' });

      if (keepsOriginal(blob.size, cfg.originalSizeBytes,
          cfg.keepOriginalIfLarger, cfg.minSavingsPercent)) {
        return {
          url: url, outputUrl: url, sizeBytes: cfg.originalSizeBytes,
          width: srcW, height: srcH, durationMs,
          // The source is returned untouched, so report *its* codec, not the one
          // we were going to encode with.
          codec: /^(hev|hvc)/.test(vTrack.codec || '') ? 'h265' : (vTrack.codec || '').startsWith('avc') ? 'h264' : vTrack.codec || 'unknown',
          frameRate: srcFps, hasAudio: srcHasAudio, skipped: true,
        };
      }

      const outUrl = trackUrl(URL.createObjectURL(blob));
      if (onProgress) onProgress(1, blob.size);
      return {
        url: outUrl, outputUrl: outUrl, sizeBytes: blob.size,
        width: tw, height: th,
        // Derived from what was actually encoded, not from the source header.
        durationMs: encodedFrames > 0
          ? Math.round((encodedEnd - encodedStart) / 1000)
          : durationMs,
        codec: usedCodec,
        frameRate: encodedEnd > encodedStart ? encodedFrames * 1e6 / (encodedEnd - encodedStart) : srcFps,
        // v1 never carries audio through; say so instead of implying otherwise.
        hasAudio: false,
        skipped: false,
      };
    } catch (error) {
      if (cancelled.has(id) || error.name === 'AbortError') throw new Error('cancelled');
      throw error;
    } finally {
      // WebCodecs codecs hold hardware/GPU resources; leaking a pair per run
      // makes the browser refuse to create encoders after a few compressions.
      closeQuietly(decoder);
      closeQuietly(encoder);
      try { if (file) file.stop(); } catch (_) {}
      // Don't let ids pile up: cancel() adds unconditionally, including for jobs
      // that had already finished.
      cancelled.delete(id);
      active.delete(id);
    }
  };

  // ---- images (canvas + toBlob; no WebCodecs/MP4 needed) -----------------

  NS.getImageInfo = async function (url) {
    const blob = await (await fetch(url)).blob();
    const bmp = await createImageBitmap(blob);
    const info = {
      path: url, width: bmp.width, height: bmp.height,
      sizeBytes: blob.size,
      format: blob.type ? blob.type.replace('image/', '') : null,
    };
    bmp.close();
    return info;
  };

  // cfg: { format, quality, targetSizeKB, maxWidth, maxHeight, lossless }
  /**
   * Shared image core. Takes a Blob so both entry points below — a blob: URL and
   * raw bytes — run exactly the same encode, and returns the encoded Blob rather
   * than an object URL so the byte path never mints one it would have to revoke.
   */
  async function compressImageBlob(blob, cfg) {
    const bmp = await createImageBitmap(blob);

    // A null/absent format keeps the source's format. Canvas can't encode HEIC
    // → JPEG; unknowns → JPEG. Otherwise the requested format is kept.
    let fmt = cfg.format || (blob.type ? blob.type.replace('image/', '') : 'jpeg');
    if (fmt !== 'png' && fmt !== 'webp') fmt = 'jpeg';  // jpeg/jpg/heic/unknown
    const mime = fmt === 'png' ? 'image/png' : fmt === 'webp' ? 'image/webp' : 'image/jpeg';
    const lossy = fmt !== 'png';

    function fitDims(w, h) {
      let fw = w, fh = h;
      if (cfg.maxWidth && fw > cfg.maxWidth) { const s = cfg.maxWidth / fw; fw *= s; fh *= s; }
      if (cfg.maxHeight && fh > cfg.maxHeight) { const s = cfg.maxHeight / fh; fw *= s; fh *= s; }
      return [Math.max(1, Math.round(fw)), Math.max(1, Math.round(fh))];
    }
    function draw(w, h) {
      const c = document.createElement('canvas');
      c.width = w; c.height = h;
      c.getContext('2d').drawImage(bmp, 0, 0, w, h);
      return c;
    }
    function toBlob(canvas, q) {
      return new Promise((res) => canvas.toBlob((b) => res(b), mime, lossy ? q : undefined));
    }
    // Lossless → max quality (1.0); PNG ignores it and stays truly lossless.
    const baseQ = cfg.lossless ? 1 : (cfg.quality || 85) / 100;
    /**
     * Highest-quality blob that fits `target`, plus the quality it used.
     * Tries the ceiling first so an image that already fits costs one encode
     * instead of a full binary search; `minQ` lets a downscale round start from
     * the quality the previous round reached.
     */
    async function fit(canvas, target, minQ) {
      if (!lossy || !target) return { blob: await toBlob(canvas, baseQ), quality: 100 };
      const ceiling = await toBlob(canvas, 1);
      if (ceiling && ceiling.size <= target) return { blob: ceiling, quality: 100 };
      let lo = minQ, hi = 99, best = null, bestQ = minQ;
      while (lo <= hi) {
        const q = Math.floor((lo + hi) / 2);
        const b = await toBlob(canvas, q / 100);
        if (b && b.size <= target) { best = b; bestQ = q; lo = q + 1; } else { hi = q - 1; }
      }
      return { blob: best || await toBlob(canvas, minQ / 100), quality: bestQ };
    }

    // A target size can't be honored losslessly — ignore it in that case.
    const target = cfg.lossless || !cfg.targetSizeKB ? null : cfg.targetSizeKB * 1024;
    try {
      let [w, h] = fitDims(bmp.width, bmp.height);
      let canvas = draw(w, h);
      let fitted = await fit(canvas, target, 1);
      let tries = 0;
      while (target && fitted.blob && fitted.blob.size > target && tries < 24 &&
             (canvas.width > 1 || canvas.height > 1)) {
        w = Math.max(1, Math.floor(canvas.width * 0.75)); h = Math.max(1, Math.floor(canvas.height * 0.75));
        canvas = draw(w, h);
        // A smaller image fits at least the quality the last round reached.
        fitted = await fit(canvas, target, fitted.quality);
        tries++;
      }
      const out = fitted.blob;
      if (!out) throw new Error('image encode failed');
      if (target && out.size > target) throw new Error('Target image size cannot be met');

      // Re-encoding can end up larger than the source (already-compressed input,
      // or lossless). If so, hand back the untouched original.
      if (keepsOriginal(out.size, blob.size,
          cfg.keepOriginalIfLarger !== false, cfg.minSavingsPercent)) {
        return {
          blob: null,
          originalSizeBytes: blob.size,
          width: bmp.width, height: bmp.height,
          format: blob.type ? blob.type.replace('image/', '') : fmt,
          skipped: true,
        };
      }
      // toBlob silently falls back to PNG when the browser can't encode the
      // requested type (WebP on older Safari), so report what was written.
      const actual = out.type ? out.type.replace('image/', '') : fmt;
      return {
        blob: out,
        originalSizeBytes: blob.size,
        width: canvas.width, height: canvas.height, format: actual, skipped: false,
      };
    } finally {
      bmp.close();
    }
  }

  NS.compressImage = async function (url, cfg) {
    const source = await (await fetch(url)).blob();
    const out = await compressImageBlob(source, cfg);
    return {
      // Skipped: the caller's own URL is the result. `revoke` refuses to free a
      // URL it did not mint, so handing this back cannot destroy their input.
      outputPath: out.skipped ? url : trackUrl(URL.createObjectURL(out.blob)),
      originalSizeBytes: out.originalSizeBytes,
      compressedSizeBytes: out.skipped ? out.originalSizeBytes : out.blob.size,
      width: out.width,
      height: out.height,
      format: out.format,
      skipped: out.skipped,
    };
  };

  /**
   * Sniff the container from the leading bytes.
   *
   * A `Blob` built from raw bytes has an empty `type`, and the core derives
   * "keep the source's format" from exactly that field — without this a PNG
   * handed over as bytes would come back re-encoded as JPEG, unlike every other
   * entry point.
   */
  function sniffMime(bytes) {
    const b = bytes;
    if (b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) {
      return 'image/png';
    }
    if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg';
    if (b.length >= 12 &&
        b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
        b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) {
      return 'image/webp';
    }
    // ISO-BMFF: 'ftyp' at offset 4, brand at 8 (heic/heix/hevc/mif1).
    if (b.length >= 12 &&
        b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) {
      const brand = String.fromCharCode(b[8], b[9], b[10], b[11]).toLowerCase();
      if (brand.startsWith('hei') || brand.startsWith('hev') || brand === 'mif1') {
        return 'image/heic';
      }
    }
    return '';
  }

  /** In-memory variant: no object URL is created, so there is nothing to revoke. */
  NS.compressImageBytes = async function (bytes, cfg) {
    const source = new Blob([bytes], { type: sniffMime(bytes) });
    const out = await compressImageBlob(source, cfg);
    const data = out.skipped
      ? bytes
      : new Uint8Array(await out.blob.arrayBuffer());
    return {
      bytes: data,
      originalSizeBytes: out.originalSizeBytes,
      width: out.width,
      height: out.height,
      format: out.format,
      skipped: out.skipped,
    };
  };

  // ---- download / cleanup ------------------------------------------------

  const EXT_BY_MIME = {
    'video/mp4': 'mp4', 'video/quicktime': 'mov', 'video/webm': 'webm',
    'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp',
    'image/heic': 'heic', 'image/heif': 'heic',
  };

  // Derive a sensible name from the blob's own MIME type. Defaulting to .mp4
  // would label a compressed JPEG as a movie.
  async function defaultName(url) {
    let ext = 'bin';
    try {
      const type = (await (await fetch(url)).blob()).type;
      ext = EXT_BY_MIME[type] || (type.split('/')[1] || 'bin');
    } catch (_) {}
    return 'compressed_' + Date.now() + '.' + ext;
  }

  NS.download = async function (url, fileName) {
    // Sanitise: a name carrying path separators (easy to produce by parsing an
    // extension out of a blob: URL) makes the browser drop the download
    // attribute, so the file lands with no extension at all.
    const clean = fileName && fileName.replace(/[/\\]/g, '_').trim();
    const name = clean || (await defaultName(url));
    const a = document.createElement('a');
    a.href = url;
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    // Give the browser time to consume the URL before a caller releases it.
    await new Promise((resolve) => setTimeout(resolve, 1000));
    return name;
  };

  NS.revoke = function (url) {
    // Only revoke URLs we minted. When a result is `skipped` its outputUrl *is*
    // the caller's input URL, and revoking that would tear down a blob we don't
    // own — the caller would lose its own source.
    if (!OUTPUT_URLS.delete(url)) return;
    try { URL.revokeObjectURL(url); } catch (_) {}
  };

  /** Revoke every output this engine created (backs Dart's `clearCache`). */
  NS.revokeAll = function () {
    for (const url of OUTPUT_URLS) {
      try { URL.revokeObjectURL(url); } catch (_) {}
    }
    OUTPUT_URLS.clear();
    prepared = null; clearTimeout(preparedTimer);
  };
})();
