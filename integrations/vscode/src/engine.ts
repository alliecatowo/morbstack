// Connection state machine for the Morbstack engine.
//
// Holds the single DockerClient, tracks whether the socket answers, subscribes
// to the engine's own /events stream so the views update the instant something
// changes, and falls back to a slow poll so nothing is stuck if the stream
// dies. Every consumer listens to `onDidChange`.

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as vscode from 'vscode';
import { DockerClient, VersionResponse, expandPath } from './api';
import { MorbCli, MorbStatusData } from './morb';

export type EngineState = 'up' | 'down' | 'unknown';

export interface EngineSnapshot {
  state: EngineState;
  socketPath: string;
  version?: VersionResponse;
  /** Populated from `morb status --json` when the CLI is available. */
  morbStatus?: MorbStatusData;
  /** Human-readable reason the engine is unreachable, when it is. */
  reason?: string;
  morbInstalled: boolean;
}

export class Engine implements vscode.Disposable {
  readonly client: DockerClient;
  readonly morb: MorbCli;

  private snapshotValue: EngineSnapshot;
  private eventsHandle?: { abort: () => void };
  private pollTimer?: NodeJS.Timeout;
  private reconnectTimer?: NodeJS.Timeout;
  private disposed = false;

  private readonly changeEmitter = new vscode.EventEmitter<EngineSnapshot>();
  /** Fires on engine state changes and on any engine event worth redrawing for. */
  readonly onDidChange = this.changeEmitter.event;

  constructor(private readonly output: vscode.OutputChannel) {
    const socketPath = readSocketSetting();
    this.client = new DockerClient(socketPath);
    this.morb = new MorbCli(
      vscode.workspace.getConfiguration('morbstack').get<string>('morbPath', ''),
    );
    this.snapshotValue = {
      state: 'unknown',
      socketPath,
      morbInstalled: this.morb.installed,
    };
  }

  get snapshot(): EngineSnapshot {
    return this.snapshotValue;
  }

  get isUp(): boolean {
    return this.snapshotValue.state === 'up';
  }

  async start(): Promise<void> {
    await this.probe();
    this.schedulePoll();
  }

  applyConfiguration(): void {
    this.morb.path = vscode.workspace.getConfiguration('morbstack').get<string>('morbPath', '');
    const next = readSocketSetting();
    if (next !== this.client.socketPath) {
      this.log(`socket path changed to ${next}`);
      this.client.socketPath = next;
      this.snapshotValue = { ...this.snapshotValue, socketPath: next };
      this.stopEvents();
    }
    this.schedulePoll();
    void this.probe();
  }

  /**
   * Ask the engine whether it is there. Also resolves the socket path from
   * `morb status --json` when the configured path is missing, which is the
   * common case for a non-default MORBSTACK_HOME.
   */
  async probe(): Promise<EngineSnapshot> {
    if (this.disposed) {
      return this.snapshotValue;
    }
    const previous = this.snapshotValue.state;
    try {
      await this.client.ping();
      const version = await this.client.version();
      const morbStatus = this.morb.installed ? await this.morb.status() : undefined;
      this.set({
        state: 'up',
        socketPath: this.client.socketPath,
        version,
        morbStatus,
        morbInstalled: this.morb.installed,
      });
      if (previous !== 'up') {
        this.log(`engine up: ${version.Version} (API ${version.ApiVersion}) at ${this.client.socketPath}`);
        this.startEvents();
      }
      return this.snapshotValue;
    } catch (err) {
      const rediscovered = await this.rediscoverSocket();
      if (rediscovered) {
        return this.probe();
      }
      const reason = err instanceof Error ? err.message : String(err);
      this.stopEvents();
      this.set({
        state: 'down',
        socketPath: this.client.socketPath,
        reason,
        morbInstalled: this.morb.installed,
      });
      if (previous !== 'down') {
        this.log(`engine down: ${reason}`);
      }
      return this.snapshotValue;
    }
  }

  /**
   * If the configured socket file does not exist but `morb status` reports a
   * different one, adopt it for this session. The setting is left alone: the
   * user's configuration is not silently rewritten.
   */
  private async rediscoverSocket(): Promise<boolean> {
    if (!this.morb.installed || fs.existsSync(this.client.socketPath)) {
      return false;
    }
    const status = await this.morb.status();
    const reported = status?.docker_socket;
    if (typeof reported === 'string' && reported.length > 0 && reported !== this.client.socketPath) {
      this.log(`configured socket missing; using ${reported} reported by \`morb status\``);
      this.client.socketPath = reported;
      return true;
    }
    return false;
  }

  private startEvents(): void {
    this.stopEvents();
    if (this.disposed) {
      return;
    }
    const filters = encodeURIComponent(
      JSON.stringify({ type: ['container', 'image', 'volume', 'network'] }),
    );
    this.eventsHandle = this.client.openStream(
      `/events?filters=${filters}`,
      (res) => {
        res.setEncoding('utf8');
        let pending = '';
        res.on('data', (chunk: string) => {
          pending += chunk;
          // The event stream is newline-delimited JSON. We do not need the
          // payload itself, only the fact that something changed.
          let index = pending.indexOf('\n');
          let sawEvent = false;
          while (index !== -1) {
            if (pending.slice(0, index).trim().length > 0) {
              sawEvent = true;
            }
            pending = pending.slice(index + 1);
            index = pending.indexOf('\n');
          }
          if (sawEvent) {
            this.changeEmitter.fire(this.snapshotValue);
          }
        });
        res.on('end', () => this.onEventsClosed('stream ended'));
        res.on('error', (err: Error) => this.onEventsClosed(err.message));
      },
      (err) => this.onEventsClosed(err.message),
    );
  }

  private onEventsClosed(reason: string): void {
    if (this.disposed || !this.eventsHandle) {
      return;
    }
    this.eventsHandle = undefined;
    this.log(`event stream closed (${reason}); will re-probe`);
    this.reconnectTimer = setTimeout(() => void this.probe(), 2_000);
  }

  private stopEvents(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = undefined;
    }
    if (this.eventsHandle) {
      const handle = this.eventsHandle;
      this.eventsHandle = undefined;
      handle.abort();
    }
  }

  private schedulePoll(): void {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = undefined;
    }
    const seconds = vscode.workspace.getConfiguration('morbstack').get<number>('refreshInterval', 5);
    // Even with polling disabled we keep a slow liveness probe, otherwise a
    // stopped engine would never be noticed (no events arrive from a dead socket).
    const intervalMs = seconds > 0 ? seconds * 1000 : 30_000;
    this.pollTimer = setInterval(() => void this.probe(), intervalMs);
  }

  private set(next: EngineSnapshot): void {
    this.snapshotValue = next;
    this.changeEmitter.fire(next);
  }

  private log(message: string): void {
    this.output.appendLine(`[${new Date().toISOString()}] ${message}`);
  }

  dispose(): void {
    this.disposed = true;
    this.stopEvents();
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
    }
    this.changeEmitter.dispose();
  }
}

function readSocketSetting(): string {
  const configured = vscode.workspace
    .getConfiguration('morbstack')
    .get<string>('socketPath', '~/.morbstack/run/docker.sock');
  const expanded = expandPath(configured);
  return expanded.length > 0
    ? expanded
    : path.join(os.homedir(), '.morbstack', 'run', 'docker.sock');
}
