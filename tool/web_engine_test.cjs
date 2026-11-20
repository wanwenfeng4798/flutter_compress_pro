const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
vm.runInThisContext(fs.readFileSync('assets/mp4box.all.min.js', 'utf8'));
vm.runInThisContext(fs.readFileSync('assets/mp4-muxer.js', 'utf8'));
const description = Uint8Array.from(Buffer.from('0142c01effe100096742c01eda7b01100001000468ce3c80', 'hex'));
const metadata = { decoderConfig: { codec: 'avc1.42c01e', description, codedWidth: 16, codedHeight: 16 } };
const source = new Mp4Muxer.Muxer({ target: new Mp4Muxer.ArrayBufferTarget(),
  video: { codec: 'avc', width: 16, height: 16 }, fastStart: 'in-memory' });
for (let i = 0; i < 60; i++) {
  source.addVideoChunkRaw(new Uint8Array([0, 0, 0, 2, 0x65, 0]), 'key', i * 16667, 16667, metadata);
}
source.finalize();
// Same clip with an AAC-LC track (48 kHz stereo, ~1 s) for audio passthrough.
const av = new Mp4Muxer.Muxer({ target: new Mp4Muxer.ArrayBufferTarget(),
  video: { codec: 'avc', width: 16, height: 16 },
  audio: { codec: 'aac', numberOfChannels: 2, sampleRate: 48000 },
  fastStart: 'in-memory', firstTimestampBehavior: 'cross-track-offset' });
for (let i = 0; i < 60; i++) {
  av.addVideoChunkRaw(new Uint8Array([0, 0, 0, 2, 0x65, 0]), 'key', i * 16667, 16667, metadata);
}
const audioMeta = { decoderConfig: { codec: 'mp4a.40.2', numberOfChannels: 2, sampleRate: 48000,
  description: Uint8Array.from([0x11, 0x90]) } };
for (let i = 0; i < 47; i++) {
  av.addAudioChunkRaw(new Uint8Array(64).fill(1), 'key', i * 21333, 21333, audioMeta);
}
av.finalize();
let fetches = 0;
let failConfigure = false;
const codecs = [];
class Chunk {
  constructor(init) { Object.assign(this, init); this.byteLength = this.data.length; }
  copyTo(destination) { destination.set(this.data); }
}
class Frame {
  constructor(init) { Object.assign(this, init); }
  close() {}
}
class Encoder {
  constructor(callbacks) { this.callbacks = callbacks; this.state = 'unconfigured'; this.encodeQueueSize = 0; codecs.push(this); }
  static async isConfigSupported() { return { supported: true }; }
  configure(config) { if (failConfigure) throw new Error('configure failed'); this.config = config; this.state = 'configured'; }
  encode(frame) {
    this.callbacks.output(new Chunk({ data: new Uint8Array([0, 0, 0, 2, 0x65, 0]),
      type: 'key', timestamp: frame.timestamp, duration: frame.duration }), metadata);
  }
  async flush() {}
  close() { this.state = 'closed'; }
}
class Decoder {
  constructor(callbacks) { this.callbacks = callbacks; this.state = 'unconfigured'; this.decodeQueueSize = 0; codecs.push(this); }
  configure() { this.state = 'configured'; this.needsKey = true; }
  decode(chunk) {
    assert.equal(this.needsKey && chunk.type !== 'key', false);
    this.needsKey = false;
    this.callbacks.output(new Frame(chunk));
  }
  async flush() { this.needsKey = true; }
  close() { this.state = 'closed'; }
}
Object.assign(globalThis, { window: globalThis, VideoEncoder: Encoder, VideoDecoder: Decoder,
  EncodedVideoChunk: Chunk, VideoFrame: Frame,
  fetch: async (url, options) => {
    fetches++;
    if (url === 'offline') throw new Error('offline');
    if (url === 'wait') return new Promise((_, reject) => { options.signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true }); });
    if (typeof url === 'string' && url.startsWith('blob:')) {
      const blob = require('node:buffer').resolveObjectURL(url);
      if (blob) { const data = await blob.arrayBuffer(); return { ok: true, arrayBuffer: async () => data.slice(0) }; }
    }
    const buffer = url === 'av' ? av.target.buffer : source.target.buffer;
    return { ok: true, arrayBuffer: async () => buffer.slice(0) };
  },
});
vm.runInThisContext(fs.readFileSync('assets/flutter_compress_pro_web.js', 'utf8'));
const config = { id: 'ok', targetWidth: 16, targetHeight: 16, videoBitrateBps: 100000,
  frameRate: 30, originalSizeBytes: source.target.buffer.byteLength, keepOriginalIfLarger: false };
(async () => {
  await flutterCompressWeb.getInfo('source');
  const result = await flutterCompressWeb.compress('source', config);
  assert.equal(fetches, 1, 'metadata buffer should be reused');
  assert.ok(Math.abs(result.durationMs - 1000) < 5, '60 frames must not be reported as 2s at the requested 30fps');
  assert.ok(Math.abs(result.frameRate - 60) < 0.1);
  assert.equal(result.hasAudio, false);
  flutterCompressWeb.revoke(result.outputUrl);
  assert.ok(codecs.every((codec) => codec.state === 'closed'));
  failConfigure = true;
  await assert.rejects(flutterCompressWeb.compress('source', { ...config, id: 'bad-config' }), /configure/);
  assert.ok(codecs.every((codec) => codec.state === 'closed'), 'configuration failure must close encoders');
  failConfigure = false;
  const cancelledInfo = flutterCompressWeb.getInfo('wait', 'cancel-metadata');
  flutterCompressWeb.cancel('cancel-metadata');
  await assert.rejects(cancelledInfo, /cancelled/);
  await assert.rejects(flutterCompressWeb.compress('offline', { ...config, id: 'offline' }), /offline/);
  const retry = await flutterCompressWeb.compress('source', { ...config, id: 'offline' });
  assert.ok(retry.durationMs > 0);
  // Frame-rate cap: 60 fps source capped to 30 keeps roughly half the frames.
  const capped = await flutterCompressWeb.compress('source', { ...config, id: 'cap', capFrameRate: 30 });
  assert.ok(Math.abs(capped.frameRate - 30) < 3, `capped fps ${capped.frameRate}`);
  assert.ok(Math.abs(capped.durationMs - 1000) < 40, `capped duration ${capped.durationMs}`);
  // A cap at or above the source rate never changes it.
  const uncapped = await flutterCompressWeb.compress('source', { ...config, id: 'nocap', capFrameRate: 120 });
  assert.ok(Math.abs(uncapped.frameRate - 60) < 0.1);

  // Trim: only the requested window is encoded.
  const trimmed = await flutterCompressWeb.compress('source', {
    ...config, id: 'trim', trimStartMs: 250, trimEndMs: 750 });
  assert.ok(Math.abs(trimmed.durationMs - 500) < 40, `trimmed duration ${trimmed.durationMs}`);
  await assert.rejects(flutterCompressWeb.compress('source', {
    ...config, id: 'empty-trim', trimStartMs: 5000, trimEndMs: 6000 }));

  // Audio: AAC-LC is copied through, trimmed with the video, or removed on request.
  const avInfo = await flutterCompressWeb.getInfo('av');
  assert.equal(avInfo.audioPassthrough, true);
  assert.equal((await flutterCompressWeb.getInfo('source')).audioPassthrough, false);
  const withAudio = await flutterCompressWeb.compress('av', { ...config, id: 'audio' });
  assert.equal(withAudio.hasAudio, true);
  const avOut = await flutterCompressWeb.getInfo(withAudio.outputUrl);
  assert.equal(avOut.hasAudio, true);
  assert.ok(Math.abs(avOut.durationMs - 1000) < 60);
  const noAudio = await flutterCompressWeb.compress('av', { ...config, id: 'noaudio', removeAudio: true });
  assert.equal(noAudio.hasAudio, false);
  const trimmedAv = await flutterCompressWeb.compress('av', {
    ...config, id: 'trim-av', trimStartMs: 250, trimEndMs: 750 });
  assert.equal(trimmedAv.hasAudio, true);
  const trimmedOut = await flutterCompressWeb.getInfo(trimmedAv.outputUrl);
  assert.ok(Math.abs(trimmedOut.durationMs - 500) < 60, `trimmed av ${trimmedOut.durationMs}`);
  flutterCompressWeb.revokeAll();
  console.log('Web buffer reuse, batched demux, timing, failure cleanup and retry: PASS');
})().catch((error) => { console.error(error); process.exitCode = 1; });
