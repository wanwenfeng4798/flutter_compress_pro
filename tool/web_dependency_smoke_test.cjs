// Run from the repository root: node tool/web_dependency_smoke_test.cjs
// Synthetic AVC samples verify MP4 structure and extraction, not decodability.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

vm.runInThisContext(fs.readFileSync('assets/mp4box.all.min.js', 'utf8'));
vm.runInThisContext(fs.readFileSync('assets/mp4-muxer.js', 'utf8'));

const muxer = new Mp4Muxer.Muxer({
  target: new Mp4Muxer.ArrayBufferTarget(),
  video: { codec: 'avc', width: 16, height: 16 },
  fastStart: 'in-memory',
  firstTimestampBehavior: 'offset',
});
const description = Uint8Array.from(Buffer.from(
  '0142c01effe100096742c01eda7b01100001000468ce3c80', 'hex',
));
for (let i = 0; i < 3; i++) {
  muxer.addVideoChunkRaw(
    new Uint8Array([0, 0, 0, 2, 0x65, 0]), 'key', i * 40000, 40000,
    {
      decoderConfig: {
        codec: 'avc1.42c01e',
        codedWidth: 16,
        codedHeight: 16,
        description,
      },
    },
  );
}
muxer.finalize();

// Match the engine: retain data, append, flush, then configure extraction.
const file = MP4Box.createFile(true);
let info;
file.onError = (error) => { throw new Error(String(error)); };
file.onReady = (value) => { info = value; };
const buffer = muxer.target.buffer;
buffer.fileStart = 0;
file.appendBuffer(buffer);
file.flush();
assert.equal(info.videoTracks.length, 1);
assert.equal(info.videoTracks[0].nb_samples, 3);

// Match avcDescription(): serialise avcC and remove its eight-byte box header.
const track = file.getTrackById(info.videoTracks[0].id);
const stream = new DataStream(undefined, 0, DataStream.BIG_ENDIAN);
track.mdia.minf.stbl.stsd.entries[0].avcC.write(stream);
assert.deepEqual(new Uint8Array(stream.buffer, 8), description);

let extractedSamples = 0;
file.onSamples = (_, __, samples) => { extractedSamples += samples.length; };
file.setExtractionOptions(info.videoTracks[0].id, null, { nbSamples: 3 });
file.start();
assert.equal(extractedSamples, 3);
console.log('MP4 mux/demux, avcC serialization and sample extraction: PASS');
