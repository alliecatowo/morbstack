// Thin wrapper around the `morb` CLI, used for engine lifecycle, socket
// discovery, port-forward health and Kubernetes state. Everything
// container-shaped goes through the Engine API instead — `morb` is not a
// Docker CLI.

import { execFile } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { expandPath } from './api';

const APP_CANDIDATES = [
  '/Applications/Morbstack.app/Contents/MacOS/morb',
  path.join(os.homedir(), 'Applications/Morbstack.app/Contents/MacOS/morb'),
];

/**
 * Shape of `morb status --json`'s `data` object as of 0.1.0-m0. Every field is
 * optional here on purpose: the daemon's JSON is not a frozen contract, and the
 * extension must degrade to "unknown" rather than throw when a key moves.
 */
export interface MorbStatusData {
  state?: string;
  vm_state?: string;
  version?: string;
  docker_ready?: boolean;
  docker_socket?: string;
  cpus?: number;
  memory_mib?: number;
  shares?: string[];
  shares_degraded?: number;
  port_forwards?: unknown[];
  failed_port_forwards?: unknown[];
  active_connections?: number;
  auto_suspend_minutes?: number;
  guest_control?: string;
}

export interface MorbK8sData {
  installed?: boolean;
  enabled?: boolean;
  phase?: string;
  nodes?: number;
  nodes_ready?: number;
  pods?: number;
  pods_ready?: number;
  apiserver_port?: number;
  persistent?: boolean;
  message?: string;
}

export class MorbCli {
  constructor(private configuredPath: string) {}

  set path(value: string) {
    this.configuredPath = value;
  }

  /** Resolve the binary, or undefined if Morbstack does not appear to be installed. */
  resolve(): string | undefined {
    const configured = this.configuredPath.trim();
    if (configured.length > 0) {
      const expanded = expandPath(configured);
      return fs.existsSync(expanded) ? expanded : undefined;
    }
    for (const dir of (process.env.PATH ?? '').split(path.delimiter)) {
      if (dir.length === 0) {
        continue;
      }
      const candidate = path.join(dir, 'morb');
      try {
        fs.accessSync(candidate, fs.constants.X_OK);
        return candidate;
      } catch {
        /* keep looking */
      }
    }
    for (const candidate of APP_CANDIDATES) {
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }
    return undefined;
  }

  get installed(): boolean {
    return this.resolve() !== undefined;
  }

  run(args: string[], timeoutMs = 120_000): Promise<{ stdout: string; stderr: string }> {
    const bin = this.resolve();
    if (!bin) {
      return Promise.reject(
        new Error('The `morb` CLI was not found. Set morbstack.morbPath, or install Morbstack.'),
      );
    }
    return new Promise((resolve, reject) => {
      execFile(bin, args, { timeout: timeoutMs }, (err, stdout, stderr) => {
        if (err) {
          const detail = (stderr || stdout || err.message).trim();
          reject(new Error(detail.length > 0 ? detail : err.message));
          return;
        }
        resolve({ stdout, stderr });
      });
    });
  }

  /** `morb` wraps every --json payload as `{ "ok": bool, "data": {...} }`. */
  private async runJson<T>(args: string[], timeoutMs: number): Promise<T | undefined> {
    try {
      const { stdout } = await this.run(args, timeoutMs);
      const parsed = JSON.parse(stdout) as { ok?: boolean; data?: unknown };
      if (parsed && typeof parsed === 'object' && 'data' in parsed) {
        return parsed.data as T;
      }
      return parsed as unknown as T;
    } catch {
      return undefined;
    }
  }

  status(): Promise<MorbStatusData | undefined> {
    return this.runJson<MorbStatusData>(['status', '--json'], 15_000);
  }

  k8sStatus(): Promise<MorbK8sData | undefined> {
    return this.runJson<MorbK8sData>(['k8s', 'status', '--json'], 20_000);
  }

  start(): Promise<unknown> {
    return this.run(['start'], 300_000);
  }

  stop(): Promise<unknown> {
    return this.run(['stop'], 300_000);
  }
}
