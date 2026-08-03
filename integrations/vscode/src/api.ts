// Minimal Docker Engine API client over a unix domain socket.
//
// Deliberately dependency-free: Node's http module speaks to a unix socket via
// `socketPath`, and everything the extension needs (JSON calls, streaming log
// output, and hijacked exec streams) is expressible with it. Morbstack exposes
// an unmodified upstream dockerd, so this is a stock Engine API client with no
// Morbstack-specific behaviour.

import * as http from 'http';
import * as os from 'os';
import * as path from 'path';
import { Socket } from 'net';

export class DockerError extends Error {
  constructor(
    message: string,
    readonly statusCode?: number,
    readonly cause?: NodeJS.ErrnoException,
  ) {
    super(message);
    this.name = 'DockerError';
  }
}

/** Expand a leading `~` and normalise. VS Code settings often carry `~/...`. */
export function expandPath(p: string): string {
  const trimmed = p.trim();
  if (trimmed === '~') {
    return os.homedir();
  }
  if (trimmed.startsWith('~/')) {
    return path.join(os.homedir(), trimmed.slice(2));
  }
  return trimmed;
}

export interface Port {
  IP?: string;
  PrivatePort: number;
  PublicPort?: number;
  Type: string;
}

export interface ContainerSummary {
  Id: string;
  Names: string[];
  Image: string;
  ImageID: string;
  Command: string;
  Created: number;
  State: string;
  Status: string;
  Ports: Port[];
  Labels: Record<string, string>;
  Mounts?: unknown[];
}

export interface ImageSummary {
  Id: string;
  ParentId: string;
  RepoTags: string[] | null;
  RepoDigests: string[] | null;
  Created: number;
  Size: number;
  Containers: number;
}

export interface VolumeSummary {
  Name: string;
  Driver: string;
  Mountpoint: string;
  CreatedAt?: string;
  Scope: string;
  Labels: Record<string, string> | null;
  UsageData?: { Size: number; RefCount: number } | null;
}

export interface VolumeListResponse {
  Volumes: VolumeSummary[] | null;
  Warnings: string[] | null;
}

export interface VersionResponse {
  Version: string;
  ApiVersion: string;
  Os: string;
  Arch: string;
  KernelVersion?: string;
}

export interface PruneReport {
  containers: number;
  images: number;
  volumes: number;
  networks: number;
  reclaimed: number;
}

interface RawResponse {
  status: number;
  headers: http.IncomingHttpHeaders;
  body: Buffer;
}

/**
 * The extension pins no API version in the URL path. dockerd serves the
 * unversioned paths at its own current version, which is what a stock client
 * negotiating downward would land on anyway, and it keeps this client working
 * across engine upgrades without a version table.
 */
export class DockerClient {
  constructor(private socketPathValue: string) {}

  get socketPath(): string {
    return this.socketPathValue;
  }

  set socketPath(value: string) {
    this.socketPathValue = value;
  }

  private request(
    method: string,
    urlPath: string,
    body?: unknown,
    extraHeaders?: Record<string, string>,
  ): Promise<RawResponse> {
    return new Promise((resolve, reject) => {
      const payload = body === undefined ? undefined : Buffer.from(JSON.stringify(body), 'utf8');
      const headers: Record<string, string> = { Host: 'localhost', ...extraHeaders };
      if (payload) {
        headers['Content-Type'] = 'application/json';
        headers['Content-Length'] = String(payload.length);
      }

      const req = http.request(
        { socketPath: this.socketPathValue, path: urlPath, method, headers },
        (res) => {
          const chunks: Buffer[] = [];
          res.on('data', (c: Buffer) => chunks.push(c));
          res.on('end', () =>
            resolve({
              status: res.statusCode ?? 0,
              headers: res.headers,
              body: Buffer.concat(chunks),
            }),
          );
        },
      );
      req.on('error', (err: NodeJS.ErrnoException) => reject(translate(err, this.socketPathValue)));
      if (payload) {
        req.write(payload);
      }
      req.end();
    });
  }

  private async call<T>(method: string, urlPath: string, body?: unknown): Promise<T> {
    const res = await this.request(method, urlPath, body);
    const text = res.body.toString('utf8');
    if (res.status >= 200 && res.status < 300) {
      if (text.length === 0) {
        return undefined as unknown as T;
      }
      try {
        return JSON.parse(text) as T;
      } catch {
        return undefined as unknown as T;
      }
    }
    let message = text;
    try {
      const parsed = JSON.parse(text) as { message?: string };
      if (parsed.message) {
        message = parsed.message;
      }
    } catch {
      /* not JSON; use the raw text */
    }
    throw new DockerError(message || `HTTP ${res.status}`, res.status);
  }

  ping(): Promise<void> {
    return this.call<void>('GET', '/_ping');
  }

  version(): Promise<VersionResponse> {
    return this.call<VersionResponse>('GET', '/version');
  }

  listContainers(all: boolean): Promise<ContainerSummary[]> {
    return this.call<ContainerSummary[]>('GET', `/containers/json?all=${all ? 1 : 0}`);
  }

  listImages(): Promise<ImageSummary[]> {
    return this.call<ImageSummary[]>('GET', '/images/json');
  }

  listVolumes(): Promise<VolumeListResponse> {
    return this.call<VolumeListResponse>('GET', '/volumes');
  }

  inspectContainer(id: string): Promise<unknown> {
    return this.call<unknown>('GET', `/containers/${encodeURIComponent(id)}/json`);
  }

  inspectImage(id: string): Promise<unknown> {
    return this.call<unknown>('GET', `/images/${encodeURIComponent(id)}/json`);
  }

  inspectVolume(name: string): Promise<unknown> {
    return this.call<unknown>('GET', `/volumes/${encodeURIComponent(name)}`);
  }

  startContainer(id: string): Promise<void> {
    return this.call<void>('POST', `/containers/${encodeURIComponent(id)}/start`);
  }

  stopContainer(id: string): Promise<void> {
    return this.call<void>('POST', `/containers/${encodeURIComponent(id)}/stop`);
  }

  restartContainer(id: string): Promise<void> {
    return this.call<void>('POST', `/containers/${encodeURIComponent(id)}/restart`);
  }

  removeContainer(id: string, force: boolean): Promise<void> {
    return this.call<void>(
      'DELETE',
      `/containers/${encodeURIComponent(id)}?force=${force ? 1 : 0}&v=0`,
    );
  }

  removeImage(id: string, force: boolean): Promise<void> {
    return this.call<void>('DELETE', `/images/${encodeURIComponent(id)}?force=${force ? 1 : 0}`);
  }

  removeVolume(name: string, force: boolean): Promise<void> {
    return this.call<void>('DELETE', `/volumes/${encodeURIComponent(name)}?force=${force ? 1 : 0}`);
  }

  async prune(includeVolumes: boolean): Promise<PruneReport> {
    const report: PruneReport = {
      containers: 0,
      images: 0,
      volumes: 0,
      networks: 0,
      reclaimed: 0,
    };

    const containers = await this.call<{
      ContainersDeleted: string[] | null;
      SpaceReclaimed: number;
    }>('POST', '/containers/prune');
    report.containers = containers?.ContainersDeleted?.length ?? 0;
    report.reclaimed += containers?.SpaceReclaimed ?? 0;

    const images = await this.call<{
      ImagesDeleted: unknown[] | null;
      SpaceReclaimed: number;
    }>('POST', '/images/prune?filters=' + encodeURIComponent('{"dangling":{"true":true}}'));
    report.images = images?.ImagesDeleted?.length ?? 0;
    report.reclaimed += images?.SpaceReclaimed ?? 0;

    const networks = await this.call<{ NetworksDeleted: string[] | null }>(
      'POST',
      '/networks/prune',
    );
    report.networks = networks?.NetworksDeleted?.length ?? 0;

    if (includeVolumes) {
      const volumes = await this.call<{
        VolumesDeleted: string[] | null;
        SpaceReclaimed: number;
      }>('POST', '/volumes/prune');
      report.volumes = volumes?.VolumesDeleted?.length ?? 0;
      report.reclaimed += volumes?.SpaceReclaimed ?? 0;
    }

    return report;
  }

  /**
   * Open a streaming GET and hand back the raw IncomingMessage. The caller owns
   * the lifetime: call `abort()` to tear the request down.
   */
  openStream(
    urlPath: string,
    onResponse: (res: http.IncomingMessage) => void,
    onError: (err: Error) => void,
  ): { abort: () => void } {
    const req = http.request(
      {
        socketPath: this.socketPathValue,
        path: urlPath,
        method: 'GET',
        headers: { Host: 'localhost' },
      },
      (res) => {
        if ((res.statusCode ?? 0) >= 400) {
          const chunks: Buffer[] = [];
          res.on('data', (c: Buffer) => chunks.push(c));
          res.on('end', () =>
            onError(
              new DockerError(
                Buffer.concat(chunks).toString('utf8') || `HTTP ${res.statusCode}`,
                res.statusCode,
              ),
            ),
          );
          return;
        }
        onResponse(res);
      },
    );
    req.on('error', (err: NodeJS.ErrnoException) => onError(translate(err, this.socketPathValue)));
    req.end();
    return { abort: () => req.destroy() };
  }

  /** Create an exec instance and return its id. */
  async execCreate(
    containerId: string,
    cmd: string[],
    tty: boolean,
  ): Promise<string> {
    const res = await this.call<{ Id: string }>(
      'POST',
      `/containers/${encodeURIComponent(containerId)}/exec`,
      {
        AttachStdin: true,
        AttachStdout: true,
        AttachStderr: true,
        Tty: tty,
        Cmd: cmd,
      },
    );
    return res.Id;
  }

  /**
   * Start an exec instance with an HTTP upgrade so we get the raw bidirectional
   * socket dockerd hijacks. This is the documented `Connection: Upgrade` /
   * `Upgrade: tcp` path; dockerd answers 101 and then speaks raw bytes.
   */
  execStart(execId: string, tty: boolean): Promise<Socket> {
    return new Promise((resolve, reject) => {
      const payload = Buffer.from(JSON.stringify({ Detach: false, Tty: tty }), 'utf8');
      const req = http.request({
        socketPath: this.socketPathValue,
        path: `/exec/${encodeURIComponent(execId)}/start`,
        method: 'POST',
        headers: {
          Host: 'localhost',
          'Content-Type': 'application/json',
          'Content-Length': String(payload.length),
          Connection: 'Upgrade',
          Upgrade: 'tcp',
        },
      });
      req.on('upgrade', (_res, socket: Socket, head: Buffer) => {
        if (head && head.length > 0) {
          socket.unshift(head);
        }
        resolve(socket);
      });
      // Some engine builds answer 200 with a hijacked body instead of 101.
      req.on('response', (res) => {
        if ((res.statusCode ?? 0) >= 400) {
          const chunks: Buffer[] = [];
          res.on('data', (c: Buffer) => chunks.push(c));
          res.on('end', () =>
            reject(
              new DockerError(
                Buffer.concat(chunks).toString('utf8') || `HTTP ${res.statusCode}`,
                res.statusCode,
              ),
            ),
          );
          return;
        }
        resolve(res.socket as Socket);
      });
      req.on('error', (err: NodeJS.ErrnoException) => reject(translate(err, this.socketPathValue)));
      req.write(payload);
      req.end();
    });
  }

  async execResize(execId: string, rows: number, cols: number): Promise<void> {
    try {
      await this.call<void>('POST', `/exec/${encodeURIComponent(execId)}/resize?h=${rows}&w=${cols}`);
    } catch {
      // A resize on an exec that has already exited is a 404/409. Not worth
      // surfacing: the terminal is about to close anyway.
    }
  }

  execInspect(execId: string): Promise<{ Running: boolean; ExitCode: number | null }> {
    return this.call<{ Running: boolean; ExitCode: number | null }>(
      'GET',
      `/exec/${encodeURIComponent(execId)}/json`,
    );
  }
}

function translate(err: NodeJS.ErrnoException, socketPath: string): DockerError {
  switch (err.code) {
    case 'ENOENT':
      return new DockerError(
        `No socket at ${socketPath}. The Morbstack engine is not running, or the socket path setting is wrong.`,
        undefined,
        err,
      );
    case 'ECONNREFUSED':
      return new DockerError(
        `Nothing is listening on ${socketPath}. The Morbstack engine looks stopped.`,
        undefined,
        err,
      );
    case 'EACCES':
      return new DockerError(
        `Permission denied opening ${socketPath}.`,
        undefined,
        err,
      );
    default:
      return new DockerError(err.message, undefined, err);
  }
}
