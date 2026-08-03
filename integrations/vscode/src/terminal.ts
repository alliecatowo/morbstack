// An interactive shell inside a container, implemented directly against the
// Engine API's exec endpoints.
//
// This deliberately does not shell out to `docker exec`: the docker CLI may not
// be installed, and if it is, it would need DOCKER_HOST plumbed into the
// terminal environment. Talking to the socket ourselves means "open a shell"
// works with nothing installed but Morbstack.

import { Socket } from 'net';
import * as vscode from 'vscode';
import { DockerClient } from './api';

/** Ordered attempt: honour a configured shell, else prefer bash and fall back to sh. */
function shellCommand(configured: string): string[] {
  const trimmed = configured.trim();
  if (trimmed.length > 0) {
    return ['/bin/sh', '-c', `exec ${trimmed}`];
  }
  return [
    '/bin/sh',
    '-c',
    'if command -v bash >/dev/null 2>&1; then exec bash; else exec /bin/sh; fi',
  ];
}

class ExecPty implements vscode.Pseudoterminal {
  private readonly writeEmitter = new vscode.EventEmitter<string>();
  private readonly closeEmitter = new vscode.EventEmitter<number>();
  readonly onDidWrite = this.writeEmitter.event;
  readonly onDidClose = this.closeEmitter.event;

  private socket?: Socket;
  private execId?: string;
  private closed = false;

  constructor(
    private readonly client: DockerClient,
    private readonly containerId: string,
    private readonly configuredShell: string,
  ) {}

  async open(initialDimensions: vscode.TerminalDimensions | undefined): Promise<void> {
    try {
      this.execId = await this.client.execCreate(
        this.containerId,
        shellCommand(this.configuredShell),
        true,
      );
      const socket = await this.client.execStart(this.execId, true);
      this.socket = socket;
      socket.setNoDelay(true);

      if (initialDimensions) {
        await this.client.execResize(
          this.execId,
          initialDimensions.rows,
          initialDimensions.columns,
        );
      }

      socket.on('data', (chunk: Buffer) => this.writeEmitter.fire(chunk.toString('utf8')));
      socket.on('error', (err: Error) => this.fail(err.message));
      socket.on('close', () => void this.finish());
    } catch (err) {
      this.fail(err instanceof Error ? err.message : String(err));
    }
  }

  handleInput(data: string): void {
    this.socket?.write(data, 'utf8');
  }

  setDimensions(dimensions: vscode.TerminalDimensions): void {
    if (this.execId) {
      void this.client.execResize(this.execId, dimensions.rows, dimensions.columns);
    }
  }

  close(): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.socket?.destroy();
  }

  private async finish(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    let code = 0;
    if (this.execId) {
      try {
        const info = await this.client.execInspect(this.execId);
        code = info.ExitCode ?? 0;
      } catch {
        /* the exec is gone; report a clean exit */
      }
    }
    this.closeEmitter.fire(code);
  }

  private fail(message: string): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.writeEmitter.fire(`\r\n\x1b[31mMorbstack: ${message}\x1b[0m\r\n`);
    this.closeEmitter.fire(1);
  }
}

export function openContainerShell(
  client: DockerClient,
  containerId: string,
  label: string,
  configuredShell: string,
): vscode.Terminal {
  const pty = new ExecPty(client, containerId, configuredShell);
  const terminal = vscode.window.createTerminal({
    name: `morb: ${label}`,
    pty,
    iconPath: new vscode.ThemeIcon('terminal-linux'),
  });
  terminal.show();
  return terminal;
}
