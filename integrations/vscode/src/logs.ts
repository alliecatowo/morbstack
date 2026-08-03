// Follow a container's logs into a dedicated output channel.
//
// Containers created without a TTY get dockerd's stdcopy framing, so the stream
// has to be demultiplexed; TTY containers emit raw bytes. We read Config.Tty
// from the inspect payload and pick accordingly.

import * as vscode from 'vscode';
import { DockerClient } from './api';
import { Demuxer } from './demux';

interface Session {
  channel: vscode.OutputChannel;
  abort: () => void;
}

export class LogViewer implements vscode.Disposable {
  private readonly sessions = new Map<string, Session>();

  constructor(private readonly client: DockerClient) {}

  async show(containerId: string, label: string, tail: number): Promise<void> {
    const existing = this.sessions.get(containerId);
    if (existing) {
      existing.channel.show(true);
      return;
    }

    const channel = vscode.window.createOutputChannel(`Morbstack: ${label}`);
    channel.show(true);

    let tty = false;
    try {
      const info = (await this.client.inspectContainer(containerId)) as {
        Config?: { Tty?: boolean };
      };
      tty = info?.Config?.Tty === true;
    } catch {
      // Fall through with tty=false: stdcopy framing is the common case, and a
      // mis-guess only affects the first 8 bytes of a TTY stream.
    }

    const write = (text: string) => {
      // Docker sends \r\n on TTY streams; the output channel renders \r badly.
      channel.append(text.replace(/\r\n/g, '\n'));
    };

    const demuxer = new Demuxer((_kind, payload) => write(payload.toString('utf8')));

    const handle = this.client.openStream(
      `/containers/${encodeURIComponent(containerId)}/logs?stdout=1&stderr=1&follow=1&timestamps=0&tail=${tail}`,
      (res) => {
        res.on('data', (chunk: Buffer) => {
          if (tty) {
            write(chunk.toString('utf8'));
          } else {
            demuxer.push(chunk);
          }
        });
        res.on('end', () => {
          channel.appendLine('\n--- log stream ended ---');
          this.sessions.delete(containerId);
        });
        res.on('error', (err: Error) => {
          channel.appendLine(`\n--- log stream error: ${err.message} ---`);
          this.sessions.delete(containerId);
        });
      },
      (err) => {
        channel.appendLine(`Cannot read logs: ${err.message}`);
        this.sessions.delete(containerId);
      },
    );

    this.sessions.set(containerId, {
      channel,
      abort: () => {
        handle.abort();
        channel.dispose();
      },
    });
  }

  dispose(): void {
    for (const session of this.sessions.values()) {
      session.abort();
    }
    this.sessions.clear();
  }
}
