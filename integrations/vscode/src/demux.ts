// Demultiplexer for Docker's stdcopy stream framing.
//
// When a container was created without a TTY, dockerd interleaves stdout and
// stderr on one connection using an 8-byte header per frame:
//
//   byte 0      stream type (0 stdin, 1 stdout, 2 stderr)
//   bytes 1-3   zero padding
//   bytes 4-7   payload length, big-endian uint32
//
// With a TTY the stream is raw and must not be run through this.

export type StreamKind = 'stdin' | 'stdout' | 'stderr';

export class Demuxer {
  private buffer: Buffer = Buffer.alloc(0);

  constructor(private readonly onFrame: (kind: StreamKind, payload: Buffer) => void) {}

  push(chunk: Buffer): void {
    this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);

    for (;;) {
      if (this.buffer.length < 8) {
        return;
      }
      const length = this.buffer.readUInt32BE(4);
      if (this.buffer.length < 8 + length) {
        return;
      }
      const kind = kindOf(this.buffer[0]);
      const payload = this.buffer.subarray(8, 8 + length);
      this.buffer = this.buffer.subarray(8 + length);
      this.onFrame(kind, payload);
    }
  }
}

function kindOf(b: number): StreamKind {
  if (b === 2) {
    return 'stderr';
  }
  if (b === 0) {
    return 'stdin';
  }
  return 'stdout';
}
