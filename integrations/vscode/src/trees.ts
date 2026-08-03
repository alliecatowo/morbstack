// Tree data providers for the four Morbstack views.

import * as vscode from 'vscode';
import { ContainerSummary, ImageSummary, Port, VolumeSummary } from './api';
import { Engine } from './engine';
import { MorbK8sData } from './morb';

const COMPOSE_PROJECT = 'com.docker.compose.project';
const COMPOSE_SERVICE = 'com.docker.compose.service';

export type Node =
  | { kind: 'project'; name: string; containers: ContainerSummary[] }
  | { kind: 'container'; container: ContainerSummary }
  | { kind: 'port'; container: ContainerSummary; port: Port }
  | { kind: 'image'; image: ImageSummary }
  | { kind: 'volume'; volume: VolumeSummary }
  | { kind: 'info'; label: string; detail?: string; icon?: string }
  | { kind: 'error'; label: string; detail?: string };

abstract class BaseProvider<T extends Node> implements vscode.TreeDataProvider<T> {
  protected readonly emitter = new vscode.EventEmitter<T | undefined>();
  readonly onDidChangeTreeData = this.emitter.event;

  constructor(protected readonly engine: Engine) {}

  refresh(): void {
    this.emitter.fire(undefined);
  }

  abstract getTreeItem(element: T): vscode.TreeItem;
  abstract getChildren(element?: T): Promise<T[]>;

  protected errorNode(err: unknown): Node[] {
    const message = err instanceof Error ? err.message : String(err);
    return [{ kind: 'error', label: 'Cannot reach the engine', detail: message }];
  }
}

export class ContainersProvider extends BaseProvider<Node> {
  getTreeItem(element: Node): vscode.TreeItem {
    switch (element.kind) {
      case 'project': {
        const running = element.containers.filter((c) => c.State === 'running').length;
        const item = new vscode.TreeItem(
          element.name,
          vscode.TreeItemCollapsibleState.Expanded,
        );
        item.iconPath = new vscode.ThemeIcon('layers');
        item.description = `${running}/${element.containers.length} running`;
        item.contextValue = 'project';
        return item;
      }
      case 'container': {
        const c = element.container;
        const published = publishedPorts(c);
        const item = new vscode.TreeItem(
          displayName(c),
          published.length > 0
            ? vscode.TreeItemCollapsibleState.Collapsed
            : vscode.TreeItemCollapsibleState.None,
        );
        item.id = `container:${c.Id}`;
        item.description = `${c.Status} · ${c.Image}`;
        item.iconPath = stateIcon(c.State);
        item.contextValue =
          `container.${c.State === 'running' ? 'running' : 'stopped'}` +
          (published.length > 0 ? '.published' : '');
        item.tooltip = containerTooltip(c);
        item.command = {
          command: 'morbstack.container.inspect',
          title: 'Inspect Container',
          arguments: [element],
        };
        return item;
      }
      case 'port': {
        const p = element.port;
        const item = new vscode.TreeItem(
          `${p.PublicPort} → ${p.PrivatePort}/${p.Type}`,
          vscode.TreeItemCollapsibleState.None,
        );
        item.iconPath = new vscode.ThemeIcon('plug');
        item.contextValue = 'port.published';
        item.description = p.IP && p.IP !== '0.0.0.0' ? p.IP : undefined;
        item.tooltip = `http://localhost:${p.PublicPort}`;
        item.command = {
          command: 'morbstack.port.open',
          title: 'Open Port in Browser',
          arguments: [element],
        };
        return item;
      }
      default:
        return plainItem(element);
    }
  }

  async getChildren(element?: Node): Promise<Node[]> {
    if (element?.kind === 'project') {
      return element.containers.map((container) => ({ kind: 'container', container }) as Node);
    }
    if (element?.kind === 'container') {
      return publishedPorts(element.container).map(
        (port) => ({ kind: 'port', container: element.container, port }) as Node,
      );
    }
    if (element) {
      return [];
    }

    if (!this.engine.isUp) {
      return [];
    }
    const config = vscode.workspace.getConfiguration('morbstack');
    const showStopped = config.get<boolean>('showStoppedContainers', true);
    const group = config.get<boolean>('groupByComposeProject', true);

    try {
      const containers = await this.engine.client.listContainers(showStopped);
      containers.sort((a, b) => displayName(a).localeCompare(displayName(b)));
      if (containers.length === 0) {
        return [
          {
            kind: 'info',
            label: showStopped ? 'No containers' : 'No running containers',
            icon: 'info',
          },
        ];
      }
      if (!group) {
        return containers.map((container) => ({ kind: 'container', container }) as Node);
      }

      const projects = new Map<string, ContainerSummary[]>();
      const standalone: ContainerSummary[] = [];
      for (const c of containers) {
        const project = c.Labels?.[COMPOSE_PROJECT];
        if (project) {
          const list = projects.get(project) ?? [];
          list.push(c);
          projects.set(project, list);
        } else {
          standalone.push(c);
        }
      }

      const nodes: Node[] = [...projects.entries()]
        .sort((a, b) => a[0].localeCompare(b[0]))
        .map(([name, list]) => ({ kind: 'project', name, containers: list }) as Node);
      nodes.push(...standalone.map((container) => ({ kind: 'container', container }) as Node));
      return nodes;
    } catch (err) {
      return this.errorNode(err);
    }
  }
}

export class ImagesProvider extends BaseProvider<Node> {
  getTreeItem(element: Node): vscode.TreeItem {
    if (element.kind !== 'image') {
      return plainItem(element);
    }
    const img = element.image;
    const tags = img.RepoTags?.filter((t) => t !== '<none>:<none>') ?? [];
    const label = tags.length > 0 ? tags[0] : `<none> ${shortId(img.Id)}`;
    const item = new vscode.TreeItem(label, vscode.TreeItemCollapsibleState.None);
    item.id = `image:${img.Id}`;
    item.iconPath = new vscode.ThemeIcon(tags.length > 0 ? 'package' : 'circle-outline');
    item.description = `${formatBytes(img.Size)}${tags.length > 1 ? ` · +${tags.length - 1} tag${tags.length > 2 ? 's' : ''}` : ''}`;
    item.contextValue = 'image';
    item.tooltip = new vscode.MarkdownString(
      [
        tags.length > 0 ? `**Tags**\n\n${tags.map((t) => `- \`${t}\``).join('\n')}` : '**Untagged**',
        `\n**ID** \`${shortId(img.Id)}\``,
        `**Size** ${formatBytes(img.Size)}`,
        `**Created** ${new Date(img.Created * 1000).toLocaleString()}`,
      ].join('\n\n'),
    );
    item.command = {
      command: 'morbstack.image.inspect',
      title: 'Inspect Image',
      arguments: [element],
    };
    return item;
  }

  async getChildren(element?: Node): Promise<Node[]> {
    if (element || !this.engine.isUp) {
      return [];
    }
    try {
      const images = await this.engine.client.listImages();
      if (images.length === 0) {
        return [{ kind: 'info', label: 'No images', icon: 'info' }];
      }
      images.sort((a, b) => b.Created - a.Created);
      return images.map((image) => ({ kind: 'image', image }) as Node);
    } catch (err) {
      return this.errorNode(err);
    }
  }
}

export class VolumesProvider extends BaseProvider<Node> {
  getTreeItem(element: Node): vscode.TreeItem {
    if (element.kind !== 'volume') {
      return plainItem(element);
    }
    const v = element.volume;
    const item = new vscode.TreeItem(v.Name, vscode.TreeItemCollapsibleState.None);
    item.id = `volume:${v.Name}`;
    item.iconPath = new vscode.ThemeIcon('database');
    const project = v.Labels?.[COMPOSE_PROJECT];
    item.description = project ? `${v.Driver} · ${project}` : v.Driver;
    item.contextValue = 'volume';
    item.tooltip = new vscode.MarkdownString(
      [`**Mountpoint** \`${v.Mountpoint}\` *(inside the guest VM)*`, `**Driver** ${v.Driver}`].join(
        '\n\n',
      ),
    );
    item.command = {
      command: 'morbstack.volume.inspect',
      title: 'Inspect Volume',
      arguments: [element],
    };
    return item;
  }

  async getChildren(element?: Node): Promise<Node[]> {
    if (element || !this.engine.isUp) {
      return [];
    }
    try {
      const response = await this.engine.client.listVolumes();
      const volumes = response.Volumes ?? [];
      if (volumes.length === 0) {
        return [{ kind: 'info', label: 'No volumes', icon: 'info' }];
      }
      volumes.sort((a, b) => a.Name.localeCompare(b.Name));
      return volumes.map((volume) => ({ kind: 'volume', volume }) as Node);
    } catch (err) {
      return this.errorNode(err);
    }
  }
}

/**
 * Kubernetes state comes from `morb k8s status --json`, not from the Engine
 * API — k3s runs inside the same guest but is not a Docker concept. Read-only
 * on purpose: enabling a cluster is a heavyweight, confirmable action that
 * belongs in the app or the CLI.
 */
export class KubernetesProvider extends BaseProvider<Node> {
  getTreeItem(element: Node): vscode.TreeItem {
    return plainItem(element);
  }

  async getChildren(element?: Node): Promise<Node[]> {
    if (element) {
      return [];
    }
    if (!this.engine.snapshot.morbInstalled) {
      return [
        {
          kind: 'info',
          label: 'Kubernetes state needs the `morb` CLI',
          detail: 'Set morbstack.morbPath',
          icon: 'warning',
        },
      ];
    }
    const status = await this.engine.morb.k8sStatus();
    if (!status) {
      return [{ kind: 'info', label: 'Kubernetes state unavailable', icon: 'warning' }];
    }
    return k8sNodes(status);
  }
}

function k8sNodes(status: MorbK8sData): Node[] {
  const nodes: Node[] = [];
  const phase = status.phase ?? (status.enabled ? 'unknown' : 'stopped');
  nodes.push({
    kind: 'info',
    label: 'Cluster',
    detail: phase,
    icon: phase === 'running' || phase === 'ready' ? 'pass-filled' : 'circle-outline',
  });
  nodes.push({
    kind: 'info',
    label: 'Payload installed',
    detail: status.installed ? 'yes' : 'no',
    icon: status.installed ? 'pass' : 'circle-outline',
  });
  if (status.enabled) {
    nodes.push({
      kind: 'info',
      label: 'Nodes ready',
      detail: `${status.nodes_ready ?? 0}/${status.nodes ?? 0}`,
      icon: 'server',
    });
    nodes.push({
      kind: 'info',
      label: 'Pods ready',
      detail: `${status.pods_ready ?? 0}/${status.pods ?? 0}`,
      icon: 'circuit-board',
    });
    if (status.apiserver_port) {
      nodes.push({
        kind: 'info',
        label: 'API server',
        detail: `127.0.0.1:${status.apiserver_port}`,
        icon: 'plug',
      });
    }
  } else {
    nodes.push({
      kind: 'info',
      label: 'Run `morb k8s enable` to start the cluster',
      icon: 'terminal',
    });
  }
  if (status.message && status.message.length > 0) {
    nodes.push({ kind: 'info', label: status.message, icon: 'info' });
  }
  return nodes;
}

function plainItem(element: Node): vscode.TreeItem {
  if (element.kind === 'error') {
    const item = new vscode.TreeItem(element.label, vscode.TreeItemCollapsibleState.None);
    item.iconPath = new vscode.ThemeIcon('error');
    item.description = element.detail;
    item.tooltip = element.detail;
    return item;
  }
  if (element.kind === 'info') {
    const item = new vscode.TreeItem(element.label, vscode.TreeItemCollapsibleState.None);
    item.iconPath = new vscode.ThemeIcon(element.icon ?? 'info');
    item.description = element.detail;
    return item;
  }
  return new vscode.TreeItem('', vscode.TreeItemCollapsibleState.None);
}

/**
 * Published ports, deduplicated. dockerd reports one entry per address family,
 * so a single `-p 18099:8099` shows up twice (0.0.0.0 and ::). Collapsing on
 * public port + protocol is what the docker CLI effectively displays too.
 */
export function publishedPorts(c: ContainerSummary): Port[] {
  const seen = new Map<string, Port>();
  for (const p of c.Ports) {
    if (p.PublicPort === undefined) {
      continue;
    }
    const key = `${p.PublicPort}/${p.Type}/${p.PrivatePort}`;
    const existing = seen.get(key);
    // Prefer the IPv4 entry so the tooltip shows a familiar address.
    if (!existing || (existing.IP?.includes(':') && !p.IP?.includes(':'))) {
      seen.set(key, p);
    }
  }
  return [...seen.values()].sort((a, b) => (a.PublicPort ?? 0) - (b.PublicPort ?? 0));
}

export function displayName(c: ContainerSummary): string {
  const service = c.Labels?.[COMPOSE_SERVICE];
  if (service) {
    return service;
  }
  const name = c.Names?.[0] ?? '';
  return name.startsWith('/') ? name.slice(1) : name || shortId(c.Id);
}

export function shortId(id: string): string {
  const bare = id.startsWith('sha256:') ? id.slice(7) : id;
  return bare.slice(0, 12);
}

function stateIcon(state: string): vscode.ThemeIcon {
  switch (state) {
    case 'running':
      return new vscode.ThemeIcon(
        'vm-running',
        new vscode.ThemeColor('charts.green'),
      );
    case 'paused':
      return new vscode.ThemeIcon('debug-pause', new vscode.ThemeColor('charts.yellow'));
    case 'restarting':
      return new vscode.ThemeIcon('sync', new vscode.ThemeColor('charts.yellow'));
    case 'exited':
    case 'dead':
      return new vscode.ThemeIcon('vm-outline', new vscode.ThemeColor('charts.red'));
    default:
      return new vscode.ThemeIcon('vm-outline');
  }
}

function containerTooltip(c: ContainerSummary): vscode.MarkdownString {
  const lines = [
    `**${displayName(c)}**`,
    `**ID** \`${shortId(c.Id)}\``,
    `**Image** \`${c.Image}\``,
    `**State** ${c.State} — ${c.Status}`,
    `**Command** \`${c.Command}\``,
  ];
  const published = publishedPorts(c);
  if (published.length > 0) {
    lines.push(
      `**Published** ${published.map((p) => `${p.PublicPort}→${p.PrivatePort}/${p.Type}`).join(', ')}`,
    );
  }
  const md = new vscode.MarkdownString(lines.join('\n\n'));
  md.isTrusted = false;
  return md;
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  const units = ['kB', 'MB', 'GB', 'TB'];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
}
