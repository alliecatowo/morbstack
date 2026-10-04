import * as vscode from 'vscode';
import { ContainerSummary, DockerError } from './api';
import { Engine, EngineSnapshot } from './engine';
import { LogViewer } from './logs';
import {
  ContainersProvider,
  ImagesProvider,
  KubernetesProvider,
  Node,
  VolumesProvider,
  displayName,
  formatBytes,
  publishedPorts,
  shortId,
} from './trees';
import { openContainerShell } from './terminal';

export function activate(context: vscode.ExtensionContext): void {
  const output = vscode.window.createOutputChannel('Morbstack');
  context.subscriptions.push(output);

  const engine = new Engine(output);
  context.subscriptions.push(engine);

  const logs = new LogViewer(engine.client);
  context.subscriptions.push(logs);

  const containers = new ContainersProvider(engine);
  const images = new ImagesProvider(engine);
  const volumes = new VolumesProvider(engine);
  const kubernetes = new KubernetesProvider(engine);

  context.subscriptions.push(
    vscode.window.createTreeView('morbstack.containers', { treeDataProvider: containers }),
    vscode.window.createTreeView('morbstack.images', { treeDataProvider: images }),
    vscode.window.createTreeView('morbstack.volumes', { treeDataProvider: volumes }),
    vscode.window.createTreeView('morbstack.kubernetes', { treeDataProvider: kubernetes }),
  );

  const statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  statusBar.command = 'morbstack.engine.status';
  context.subscriptions.push(statusBar);

  const refreshAll = () => {
    containers.refresh();
    images.refresh();
    volumes.refresh();
    kubernetes.refresh();
  };

  let lastRunningCount = -1;
  const updateStatusBar = async (snapshot: EngineSnapshot) => {
    if (!vscode.workspace.getConfiguration('morbstack').get<boolean>('statusBar', true)) {
      statusBar.hide();
      return;
    }
    if (snapshot.state !== 'up') {
      statusBar.text = '$(circle-slash) Morbstack: stopped';
      statusBar.tooltip = snapshot.morbInstalled
        ? `${snapshot.reason ?? 'Engine unreachable'}\nClick for actions.`
        : 'Morbstack does not appear to be installed. Click for details.';
      statusBar.backgroundColor = undefined;
      statusBar.show();
      lastRunningCount = -1;
      return;
    }
    let running = lastRunningCount;
    try {
      running = (await engine.client.listContainers(false)).length;
      lastRunningCount = running;
    } catch {
      /* keep the previous count rather than flicker */
    }
    const failed = snapshot.morbStatus?.failed_port_forwards ?? [];
    const hasFailures = Array.isArray(failed) && failed.length > 0;
    statusBar.text = `${hasFailures ? '$(warning)' : '$(vm-running)'} Morbstack: ${running < 0 ? '?' : running} running`;
    statusBar.backgroundColor = hasFailures
      ? new vscode.ThemeColor('statusBarItem.warningBackground')
      : undefined;
    statusBar.tooltip = buildTooltip(snapshot, running, failed);
    statusBar.show();
  };

  context.subscriptions.push(
    engine.onDidChange((snapshot) => {
      void vscode.commands.executeCommand(
        'setContext',
        'morbstack.engineUp',
        snapshot.state === 'up',
      );
      refreshAll();
      void updateStatusBar(snapshot);
    }),
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('morbstack')) {
        engine.applyConfiguration();
        refreshAll();
        void updateStatusBar(engine.snapshot);
      }
    }),
  );

  const register = (id: string, handler: (...args: never[]) => unknown) => {
    context.subscriptions.push(
      vscode.commands.registerCommand(id, async (...args: unknown[]) => {
        try {
          await (handler as (...a: unknown[]) => unknown)(...args);
        } catch (err) {
          void vscode.window.showErrorMessage(`Morbstack: ${describe(err)}`);
          output.appendLine(`[${new Date().toISOString()}] ${id} failed: ${describe(err)}`);
        }
      }),
    );
  };

  // ---- engine lifecycle -------------------------------------------------

  register('morbstack.refresh', async () => {
    await engine.probe();
    refreshAll();
  });

  register('morbstack.engine.start', async () => {
    if (!engine.morb.installed) {
      await showNotInstalled();
      return;
    }
    await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: 'Starting the Morbstack engine' },
      async () => {
        await engine.morb.start();
        await engine.probe();
      },
    );
    refreshAll();
  });

  register('morbstack.engine.stop', async () => {
    if (!engine.morb.installed) {
      await showNotInstalled();
      return;
    }
    const choice = await vscode.window.showWarningMessage(
      'Stop the Morbstack engine? Running containers will be shut down.',
      { modal: true },
      'Stop',
    );
    if (choice !== 'Stop') {
      return;
    }
    await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: 'Stopping the Morbstack engine' },
      async () => {
        await engine.morb.stop();
        await engine.probe();
      },
    );
    refreshAll();
  });

  register('morbstack.engine.status', async () => {
    const snapshot = await engine.probe();
    const items: (vscode.QuickPickItem & { run?: () => Thenable<unknown> })[] = [];
    if (snapshot.state === 'up') {
      items.push({
        label: '$(pass-filled) Engine running',
        detail: `${snapshot.version?.Version ?? 'unknown'} · API ${snapshot.version?.ApiVersion ?? '?'} · ${snapshot.socketPath}`,
      });
      const failed = snapshot.morbStatus?.failed_port_forwards ?? [];
      if (Array.isArray(failed) && failed.length > 0) {
        items.push({
          label: `$(warning) ${failed.length} published port${failed.length === 1 ? '' : 's'} could not be bound on the Mac`,
          detail: 'Another process holds the port. docker ps still shows it as published.',
        });
      }
      items.push({
        label: '$(debug-stop) Stop engine',
        run: () => vscode.commands.executeCommand('morbstack.engine.stop'),
      });
    } else {
      items.push({
        label: '$(circle-slash) Engine not reachable',
        detail: snapshot.reason ?? `No response at ${snapshot.socketPath}`,
      });
      items.push({
        label: '$(debug-start) Start engine',
        run: () => vscode.commands.executeCommand('morbstack.engine.start'),
      });
    }
    items.push({
      label: '$(clippy) Copy DOCKER_HOST',
      run: () => vscode.commands.executeCommand('morbstack.copyDockerHost'),
    });
    items.push({
      label: '$(gear) Open settings',
      run: () => vscode.commands.executeCommand('morbstack.openSettings'),
    });
    items.push({
      label: '$(output) Show extension log',
      run: () => vscode.commands.executeCommand('morbstack.showOutput'),
    });

    const picked = await vscode.window.showQuickPick(items, { title: 'Morbstack' });
    await picked?.run?.();
  });

  register('morbstack.openSettings', () =>
    vscode.commands.executeCommand('workbench.action.openSettings', 'morbstack'),
  );

  register('morbstack.showOutput', () => {
    output.show(true);
  });

  register('morbstack.copyDockerHost', async () => {
    const value = `unix://${engine.client.socketPath}`;
    await vscode.env.clipboard.writeText(value);
    void vscode.window.showInformationMessage(`Copied ${value}`);
  });

  // ---- containers -------------------------------------------------------

  const containerOf = (node: Node | undefined): ContainerSummary => {
    if (node?.kind === 'container') {
      return node.container;
    }
    if (node?.kind === 'port') {
      return node.container;
    }
    throw new Error('No container selected.');
  };

  register('morbstack.container.start', async (node: Node) => {
    const c = containerOf(node);
    await engine.client.startContainer(c.Id);
    containers.refresh();
  });

  register('morbstack.container.stop', async (node: Node) => {
    const c = containerOf(node);
    await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Window, title: `Stopping ${displayName(c)}` },
      () => engine.client.stopContainer(c.Id),
    );
    containers.refresh();
  });

  register('morbstack.container.restart', async (node: Node) => {
    const c = containerOf(node);
    await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Window, title: `Restarting ${displayName(c)}` },
      () => engine.client.restartContainer(c.Id),
    );
    containers.refresh();
  });

  register('morbstack.container.remove', async (node: Node) => {
    const c = containerOf(node);
    const running = c.State === 'running';
    const choice = await vscode.window.showWarningMessage(
      `Remove container ${displayName(c)}?${running ? ' It is running and will be killed.' : ''}`,
      { modal: true },
      'Remove',
    );
    if (choice !== 'Remove') {
      return;
    }
    await engine.client.removeContainer(c.Id, running);
    containers.refresh();
  });

  register('morbstack.container.logs', async (node: Node) => {
    const c = containerOf(node);
    const rawTail = vscode.workspace.getConfiguration('morbstack').get<number>('logTail', 500);
    const tail = Number.isFinite(rawTail) ? Math.min(100000, Math.max(1, Math.trunc(rawTail))) : 500;
    await logs.show(c.Id, displayName(c), tail);
  });

  register('morbstack.container.shell', async (node: Node) => {
    const c = containerOf(node);
    if (c.State !== 'running') {
      void vscode.window.showWarningMessage(
        `${displayName(c)} is not running, so a shell cannot be attached.`,
      );
      return;
    }
    const shell = vscode.workspace.getConfiguration('morbstack').get<string>('shell', '');
    openContainerShell(engine.client, c.Id, displayName(c), shell);
  });

  register('morbstack.container.inspect', async (node: Node) => {
    const c = containerOf(node);
    const data = await engine.client.inspectContainer(c.Id);
    await showJson(`${displayName(c)}.json`, data);
  });

  register('morbstack.container.openPort', async (node: Node) => {
    const c = containerOf(node);
    const published = publishedPorts(c);
    if (published.length === 0) {
      void vscode.window.showWarningMessage(`${displayName(c)} has no published ports.`);
      return;
    }
    const port =
      published.length === 1
        ? published[0]
        : (
            await vscode.window.showQuickPick(
              published.map((p) => ({
                label: `${p.PublicPort} → ${p.PrivatePort}/${p.Type}`,
                port: p,
              })),
              { title: `Open a published port of ${displayName(c)}` },
            )
          )?.port;
    if (!port) {
      return;
    }
    await openPort(port.PublicPort as number);
  });

  register('morbstack.port.open', async (node: Node) => {
    if (node.kind !== 'port' || node.port.PublicPort === undefined) {
      return;
    }
    await openPort(node.port.PublicPort);
  });

  register('morbstack.compose.up', async (node: Node) => {
    if (node.kind !== 'project') {
      return;
    }
    const stopped = node.containers.filter((c) => c.State !== 'running');
    if (stopped.length === 0) {
      void vscode.window.showInformationMessage(`All containers in ${node.name} are running.`);
      return;
    }
    await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: `Starting ${node.name}` },
      async () => {
        for (const c of stopped) {
          await engine.client.startContainer(c.Id);
        }
      },
    );
    containers.refresh();
  });

  register('morbstack.compose.stop', async (node: Node) => {
    if (node.kind !== 'project') {
      return;
    }
    const running = node.containers.filter((c) => c.State === 'running');
    if (running.length === 0) {
      return;
    }
    await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: `Stopping ${node.name}` },
      async () => {
        await Promise.all(running.map((c) => engine.client.stopContainer(c.Id)));
      },
    );
    containers.refresh();
  });

  // ---- images and volumes ----------------------------------------------

  register('morbstack.image.remove', async (node: Node) => {
    if (node.kind !== 'image') {
      return;
    }
    const tags = node.image.RepoTags?.filter((t) => t !== '<none>:<none>') ?? [];
    const label = tags[0] ?? shortId(node.image.Id);
    const choice = await vscode.window.showWarningMessage(
      `Remove image ${label}?`,
      { modal: true },
      'Remove',
      'Force remove',
    );
    if (!choice) {
      return;
    }
    await engine.client.removeImage(
      tags.length === 1 ? tags[0] : node.image.Id,
      choice === 'Force remove',
    );
    images.refresh();
  });

  register('morbstack.image.inspect', async (node: Node) => {
    if (node.kind !== 'image') {
      return;
    }
    const data = await engine.client.inspectImage(node.image.Id);
    await showJson(`${shortId(node.image.Id)}.json`, data);
  });

  register('morbstack.volume.remove', async (node: Node) => {
    if (node.kind !== 'volume') {
      return;
    }
    const choice = await vscode.window.showWarningMessage(
      `Remove volume ${node.volume.Name}? Its contents are deleted permanently.`,
      { modal: true },
      'Remove',
    );
    if (choice !== 'Remove') {
      return;
    }
    await engine.client.removeVolume(node.volume.Name, false);
    volumes.refresh();
  });

  register('morbstack.volume.inspect', async (node: Node) => {
    if (node.kind !== 'volume') {
      return;
    }
    const data = await engine.client.inspectVolume(node.volume.Name);
    await showJson(`${node.volume.Name}.json`, data);
  });

  register('morbstack.prune', async () => {
    const choice = await vscode.window.showWarningMessage(
      'Prune stopped containers, dangling images and unused networks?',
      { modal: true },
      'Prune',
      'Prune, including unused volumes',
    );
    if (!choice) {
      return;
    }
    const includeVolumes = choice === 'Prune, including unused volumes';
    const report = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: 'Pruning' },
      () => engine.client.prune(includeVolumes),
    );
    void vscode.window.showInformationMessage(
      `Pruned ${report.containers} container(s), ${report.images} image(s), ${report.networks} network(s)` +
        (includeVolumes ? `, ${report.volumes} volume(s)` : '') +
        `. Reclaimed ${formatBytes(report.reclaimed)}.`,
    );
    refreshAll();
  });

  void engine.start();
}

export function deactivate(): void {
  /* disposables registered on the context handle teardown */
}

async function openPort(port: number): Promise<void> {
  await vscode.env.openExternal(vscode.Uri.parse(`http://localhost:${port}`));
}

async function showJson(name: string, data: unknown): Promise<void> {
  const doc = await vscode.workspace.openTextDocument({
    language: 'json',
    content: JSON.stringify(data, null, 2),
  });
  await vscode.window.showTextDocument(doc, { preview: true });
  void name;
}

async function showNotInstalled(): Promise<void> {
  const choice = await vscode.window.showErrorMessage(
    'The `morb` CLI was not found, so the engine cannot be started from here. Install Morbstack, or set morbstack.morbPath to the binary.',
    'Open settings',
  );
  if (choice === 'Open settings') {
    await vscode.commands.executeCommand('morbstack.openSettings');
  }
}

function buildTooltip(
  snapshot: EngineSnapshot,
  running: number,
  failed: unknown[],
): vscode.MarkdownString {
  const lines = [
    `**Morbstack engine**`,
    `Docker ${snapshot.version?.Version ?? 'unknown'} (API ${snapshot.version?.ApiVersion ?? '?'})`,
    `Socket: \`${snapshot.socketPath}\``,
    `Running containers: ${running < 0 ? 'unknown' : running}`,
  ];
  const status = snapshot.morbStatus;
  if (status) {
    if (status.cpus !== undefined && status.memory_mib !== undefined) {
      lines.push(`VM: ${status.cpus} CPU, ${Math.round(status.memory_mib / 1024)} GiB`);
    }
    if (status.shares_degraded) {
      lines.push(`Degraded shares: ${status.shares_degraded}`);
    }
  }
  if (failed.length > 0) {
    lines.push(
      `\n**Warning:** ${failed.length} published port${failed.length === 1 ? '' : 's'} could not be bound on the Mac. \`docker ps\` still lists them as published.`,
    );
  }
  const md = new vscode.MarkdownString(lines.join('\n\n'));
  md.isTrusted = false;
  return md;
}

function describe(err: unknown): string {
  if (err instanceof DockerError) {
    return err.message;
  }
  if (err instanceof Error) {
    return err.message;
  }
  return String(err);
}
