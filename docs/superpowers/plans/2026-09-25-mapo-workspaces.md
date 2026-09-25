# Mapo Workspaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn this VS Code fork into a cmux-style hub: user-named workspaces on the left, terminal/Claude tabs in the middle, and a file explorer on the right that follows the focused terminal's directory.

**Architecture:** One new workbench contribution folder `src/vs/workbench/contrib/mapo/` (no edits to the layout engine). A `MapoWorkspaceService` owns the workspace/tab model, persists it to `IStorageService`, and maps tabs to `ITerminalInstance`s that live as terminal editors. Workspace switching uses `ITerminalEditorService.detachInstance` / `openEditor`. Two view panes (Workspaces in the primary side bar, Explorer in the secondary side bar) render the model. Default configuration overrides hide the normal chrome.

**Tech Stack:** VS Code workbench (TypeScript, ES modules, DI via `@IService` decorators), `WorkbenchList`, `WorkbenchAsyncDataTree`, `ResourceLabels`, terminal editor services, mocha/electron unit tests.

**Spec:** `docs/superpowers/specs/2026-09-25-mapo-workspaces-design.md`

## Global Constraints

- Node 24.18.0 via mise. Every shell command below assumes: `export PATH="$HOME/.local/share/mise/installs/node/24.18.0/bin:$PATH"` and cwd `/Users/brunomazzardo/code/mapo`.
- Two background watchers are already running for this repo and must stay running: `npm run watch-client` (type-check only, log at `/private/tmp/claude-501/-Users-brunomazzardo-code-mapo/bf5c4805-19df-4815-9827-91eabfef56e7/scratchpad/watch-client.log`) and `npm run watch-client-transpile` (emits JS to `out/`, log at `.../scratchpad/transpile.log`). If either is not running, start it again with the same command in the background.
- Type-check gate for every task: after saving files, wait ~10s and run `tail -3 /private/tmp/claude-501/-Users-brunomazzardo-code-mapo/bf5c4805-19df-4815-9827-91eabfef56e7/scratchpad/watch-client.log`. It must say `Finished compilation with 0 errors`. If it lists errors, fix them before moving on.
- Unit test command: `./scripts/test.sh --run <path-to-test.ts>`. The runner strips `src/` and the extension and loads the compiled module from `out/`, so the transpile watcher must have emitted the file first (check `ls out/vs/workbench/contrib/mapo/...`).
- Lint: `npx eslint <changed .ts files>` must report no errors. VS Code forbids `any`, unused imports, and `console.log` in tests.
- Import paths are relative ES module paths ending in `.js`. From `src/vs/workbench/contrib/mapo/browser/` or `.../common/`: `../../../../base/...`, `../../../../platform/...`, `../../../browser/...`, `../../../common/...`, `../../../services/...`, `../../terminal/browser/...`, `../../../../nls.js`. From `src/vs/workbench/contrib/mapo/test/browser/` or `test/common/`: one more `../`.
- Every test suite calls `ensureNoDisposablesAreLeakedInTestSuite()` and registers disposables with the returned store.
- Inside an `Action2.run(accessor, ...)`, read all services from `accessor` before the first `await`; the accessor is invalid after an await.
- Commit after each task with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` as the last line of the message.
- Do not rename product.json until Task 7. `scripts/test.sh` and `scripts/code.sh` locate the Electron binary from `product.json`, and the rename requires re-downloading Electron.

---

### Task 1: Workspace model and persistence helpers

**Files:**
- Create: `src/vs/workbench/contrib/mapo/common/mapoWorkspace.ts`
- Test: `src/vs/workbench/contrib/mapo/test/common/mapoWorkspace.test.ts`

**Interfaces:**
- Produces: `MapoTabKind`, `IMapoTab { id, kind, cwd }`, `IMapoWorkspace { id, name, tabs, activeTabId? }`, `IMapoState { workspaces, activeWorkspaceId? }`, `MAPO_STORAGE_KEY`, `createWorkspace(name)`, `createTab(kind, cwd)`, `serializeState(state)`, `parseState(raw)`.

- [ ] **Step 1: Write the failing test**

```ts
// src/vs/workbench/contrib/mapo/test/common/mapoWorkspace.test.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { deepStrictEqual, notStrictEqual, ok, strictEqual } from 'assert';
import { ensureNoDisposablesAreLeakedInTestSuite } from '../../../../../base/test/common/utils.js';
import { createTab, createWorkspace, parseState, serializeState } from '../../common/mapoWorkspace.js';

suite('Mapo - workspace model', () => {

	ensureNoDisposablesAreLeakedInTestSuite();

	test('createWorkspace assigns unique ids and no tabs', () => {
		const a = createWorkspace('A');
		const b = createWorkspace('B');
		notStrictEqual(a.id, b.id);
		strictEqual(a.name, 'A');
		deepStrictEqual(a.tabs, []);
		strictEqual(a.activeTabId, undefined);
	});

	test('createTab keeps kind and cwd', () => {
		const tab = createTab('claude', '/tmp/x');
		strictEqual(tab.kind, 'claude');
		strictEqual(tab.cwd, '/tmp/x');
		ok(tab.id.length > 0);
	});

	test('serialize/parse round trip', () => {
		const ws = createWorkspace('Mesh');
		const tab = createTab('terminal', '/home/me/code');
		ws.tabs.push(tab);
		ws.activeTabId = tab.id;
		const parsed = parseState(serializeState({ workspaces: [ws], activeWorkspaceId: ws.id }));
		deepStrictEqual(parsed, { workspaces: [{ id: ws.id, name: 'Mesh', tabs: [tab], activeTabId: tab.id }], activeWorkspaceId: ws.id });
	});

	test('parse tolerates undefined and garbage', () => {
		deepStrictEqual(parseState(undefined), { workspaces: [], activeWorkspaceId: undefined });
		deepStrictEqual(parseState('not json'), { workspaces: [], activeWorkspaceId: undefined });
		deepStrictEqual(parseState('{"workspaces": 3}'), { workspaces: [], activeWorkspaceId: undefined });
	});

	test('parse drops invalid entries and dangling ids', () => {
		const raw = JSON.stringify({
			workspaces: [
				{ id: 'w1', name: 'ok', tabs: [{ id: 't1', kind: 'terminal', cwd: '/a' }, { id: 't2', kind: 'bogus', cwd: '/b' }, 5], activeTabId: 't2' },
				{ id: 7, name: 'bad' },
			],
			activeWorkspaceId: 'missing',
		});
		deepStrictEqual(parseState(raw), {
			workspaces: [{ id: 'w1', name: 'ok', tabs: [{ id: 't1', kind: 'terminal', cwd: '/a' }], activeTabId: undefined }],
			activeWorkspaceId: undefined,
		});
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --run src/vs/workbench/contrib/mapo/test/common/mapoWorkspace.test.ts`
Expected: FAIL (module `../../common/mapoWorkspace.js` not found, or the transpile watcher logs an error for the missing import).

- [ ] **Step 3: Write the implementation**

```ts
// src/vs/workbench/contrib/mapo/common/mapoWorkspace.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { generateUuid } from '../../../../base/common/uuid.js';

export type MapoTabKind = 'terminal' | 'claude';

export interface IMapoTab {
	readonly id: string;
	readonly kind: MapoTabKind;
	readonly cwd: string;
}

export interface IMapoWorkspace {
	readonly id: string;
	name: string;
	tabs: IMapoTab[];
	activeTabId: string | undefined;
}

export interface IMapoState {
	workspaces: IMapoWorkspace[];
	activeWorkspaceId: string | undefined;
}

export const MAPO_STORAGE_KEY = 'mapo.workspaces';

export function createWorkspace(name: string): IMapoWorkspace {
	return { id: generateUuid(), name, tabs: [], activeTabId: undefined };
}

export function createTab(kind: MapoTabKind, cwd: string): IMapoTab {
	return { id: generateUuid(), kind, cwd };
}

export function serializeState(state: IMapoState): string {
	return JSON.stringify(state);
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null;
}

function parseTab(value: unknown): IMapoTab | undefined {
	if (!isRecord(value) || typeof value.id !== 'string' || typeof value.cwd !== 'string') {
		return undefined;
	}
	if (value.kind !== 'terminal' && value.kind !== 'claude') {
		return undefined;
	}
	return { id: value.id, kind: value.kind, cwd: value.cwd };
}

function parseWorkspace(value: unknown): IMapoWorkspace | undefined {
	if (!isRecord(value) || typeof value.id !== 'string' || typeof value.name !== 'string') {
		return undefined;
	}
	const tabs: IMapoTab[] = [];
	if (Array.isArray(value.tabs)) {
		for (const raw of value.tabs) {
			const tab = parseTab(raw);
			if (tab) {
				tabs.push(tab);
			}
		}
	}
	const activeTabId = typeof value.activeTabId === 'string' && tabs.some(t => t.id === value.activeTabId) ? value.activeTabId : undefined;
	return { id: value.id, name: value.name, tabs, activeTabId };
}

export function parseState(raw: string | undefined): IMapoState {
	const empty: IMapoState = { workspaces: [], activeWorkspaceId: undefined };
	if (!raw) {
		return empty;
	}
	let parsed: unknown;
	try {
		parsed = JSON.parse(raw);
	} catch {
		return empty;
	}
	if (!isRecord(parsed) || !Array.isArray(parsed.workspaces)) {
		return empty;
	}
	const workspaces: IMapoWorkspace[] = [];
	for (const raw of parsed.workspaces) {
		const workspace = parseWorkspace(raw);
		if (workspace) {
			workspaces.push(workspace);
		}
	}
	const activeWorkspaceId = typeof parsed.activeWorkspaceId === 'string' && workspaces.some(w => w.id === parsed.activeWorkspaceId) ? parsed.activeWorkspaceId : undefined;
	return { workspaces, activeWorkspaceId };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --run src/vs/workbench/contrib/mapo/test/common/mapoWorkspace.test.ts`
Expected: 5 passing.

- [ ] **Step 5: Lint and commit**

```bash
npx eslint src/vs/workbench/contrib/mapo
git add src/vs/workbench/contrib/mapo
git commit -m "mapo: add workspace model and persistence helpers

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Git branch reader

**Files:**
- Create: `src/vs/workbench/contrib/mapo/browser/mapoGitBranch.ts`
- Test: `src/vs/workbench/contrib/mapo/test/browser/mapoGitBranch.test.ts`

**Interfaces:**
- Produces: `readGitBranch(fileService: IFileService, dir: URI): Promise<string | undefined>`. Walks up from `dir` until it finds `.git` (directory, or a worktree file containing `gitdir: <path>`), then reads `HEAD`. Returns the branch name for `ref: refs/heads/<name>`, the first 7 characters of a detached SHA, or `undefined` when there is no repository.

- [ ] **Step 1: Write the failing test**

```ts
// src/vs/workbench/contrib/mapo/test/browser/mapoGitBranch.test.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { strictEqual } from 'assert';
import { VSBuffer } from '../../../../../base/common/buffer.js';
import { URI } from '../../../../../base/common/uri.js';
import { ensureNoDisposablesAreLeakedInTestSuite } from '../../../../../base/test/common/utils.js';
import { FileService } from '../../../../../platform/files/common/fileService.js';
import { InMemoryFileSystemProvider } from '../../../../../platform/files/common/inMemoryFilesystemProvider.js';
import { NullLogService } from '../../../../../platform/log/common/log.js';
import { readGitBranch } from '../../browser/mapoGitBranch.js';

suite('Mapo - git branch reader', () => {

	const disposables = ensureNoDisposablesAreLeakedInTestSuite();
	let fileService: FileService;

	setup(() => {
		fileService = disposables.add(new FileService(new NullLogService()));
		disposables.add(fileService.registerProvider('mem', disposables.add(new InMemoryFileSystemProvider())));
	});

	async function write(path: string, content: string): Promise<void> {
		await fileService.writeFile(URI.parse(`mem:${path}`), VSBuffer.fromString(content));
	}

	test('reads branch from a normal repository, walking up from a subfolder', async () => {
		await write('/repo/.git/HEAD', 'ref: refs/heads/main\n');
		await fileService.createFolder(URI.parse('mem:/repo/src/deep'));
		strictEqual(await readGitBranch(fileService, URI.parse('mem:/repo/src/deep')), 'main');
	});

	test('reads branch through a worktree .git file', async () => {
		await write('/main/.git/worktrees/feat/HEAD', 'ref: refs/heads/feature/x\n');
		await write('/wt/.git', 'gitdir: /main/.git/worktrees/feat\n');
		strictEqual(await readGitBranch(fileService, URI.parse('mem:/wt')), 'feature/x');
	});

	test('returns short sha for a detached head', async () => {
		await write('/repo/.git/HEAD', 'abcdef1234567890\n');
		strictEqual(await readGitBranch(fileService, URI.parse('mem:/repo')), 'abcdef1');
	});

	test('returns undefined outside a repository', async () => {
		await fileService.createFolder(URI.parse('mem:/plain'));
		strictEqual(await readGitBranch(fileService, URI.parse('mem:/plain')), undefined);
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --run src/vs/workbench/contrib/mapo/test/browser/mapoGitBranch.test.ts`
Expected: FAIL, module `../../browser/mapoGitBranch.js` not found.

- [ ] **Step 3: Write the implementation**

```ts
// src/vs/workbench/contrib/mapo/browser/mapoGitBranch.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { dirname, isEqual, joinPath } from '../../../../base/common/resources.js';
import { URI } from '../../../../base/common/uri.js';
import { IFileService } from '../../../../platform/files/common/files.js';

const MAX_DEPTH = 64;

async function findGitDir(fileService: IFileService, folder: URI): Promise<URI | undefined> {
	const dotGit = joinPath(folder, '.git');
	let stat;
	try {
		stat = await fileService.stat(dotGit);
	} catch {
		return undefined;
	}
	if (stat.isDirectory) {
		return dotGit;
	}
	try {
		const content = (await fileService.readFile(dotGit)).value.toString().trim();
		const match = /^gitdir:\s*(.+)$/m.exec(content);
		if (!match) {
			return undefined;
		}
		const target = match[1].trim();
		return target.startsWith('/') ? folder.with({ path: target }) : joinPath(folder, target);
	} catch {
		return undefined;
	}
}

export async function readGitBranch(fileService: IFileService, dir: URI): Promise<string | undefined> {
	let current = dir;
	for (let depth = 0; depth < MAX_DEPTH; depth++) {
		const gitDir = await findGitDir(fileService, current);
		if (gitDir) {
			try {
				const head = (await fileService.readFile(joinPath(gitDir, 'HEAD'))).value.toString().trim();
				const ref = /^ref:\s*refs\/heads\/(.+)$/.exec(head);
				return ref ? ref[1] : head.slice(0, 7);
			} catch {
				return undefined;
			}
		}
		const parent = dirname(current);
		if (isEqual(parent, current)) {
			return undefined;
		}
		current = parent;
	}
	return undefined;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --run src/vs/workbench/contrib/mapo/test/browser/mapoGitBranch.test.ts`
Expected: 4 passing.

- [ ] **Step 5: Lint and commit**

```bash
npx eslint src/vs/workbench/contrib/mapo
git add src/vs/workbench/contrib/mapo
git commit -m "mapo: add git branch reader

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Explorer data source

**Files:**
- Create: `src/vs/workbench/contrib/mapo/browser/mapoExplorerDataSource.ts`
- Test: `src/vs/workbench/contrib/mapo/test/browser/mapoExplorerDataSource.test.ts`

**Interfaces:**
- Produces: `IFileNode { resource: URI; name: string; isDirectory: boolean }`, `sortFileNodes(nodes): IFileNode[]` (folders first, then `compareFileNames`), `class MapoExplorerDataSource implements IAsyncDataSource<IFileNode, IFileNode>` with `constructor(fileService: IFileService, isExcluded: (node: IFileNode) => boolean)`. `getChildren` returns `[]` when the folder cannot be resolved.

- [ ] **Step 1: Write the failing test**

```ts
// src/vs/workbench/contrib/mapo/test/browser/mapoExplorerDataSource.test.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { deepStrictEqual, strictEqual } from 'assert';
import { VSBuffer } from '../../../../../base/common/buffer.js';
import { URI } from '../../../../../base/common/uri.js';
import { ensureNoDisposablesAreLeakedInTestSuite } from '../../../../../base/test/common/utils.js';
import { FileService } from '../../../../../platform/files/common/fileService.js';
import { InMemoryFileSystemProvider } from '../../../../../platform/files/common/inMemoryFilesystemProvider.js';
import { NullLogService } from '../../../../../platform/log/common/log.js';
import { IFileNode, MapoExplorerDataSource, sortFileNodes } from '../../browser/mapoExplorerDataSource.js';

suite('Mapo - explorer data source', () => {

	const disposables = ensureNoDisposablesAreLeakedInTestSuite();
	let fileService: FileService;

	setup(() => {
		fileService = disposables.add(new FileService(new NullLogService()));
		disposables.add(fileService.registerProvider('mem', disposables.add(new InMemoryFileSystemProvider())));
	});

	function node(path: string, isDirectory: boolean): IFileNode {
		const resource = URI.parse(`mem:${path}`);
		return { resource, name: path.split('/').pop()!, isDirectory };
	}

	test('sortFileNodes puts folders first, then names in file order', () => {
		const sorted = sortFileNodes([node('/r/b.txt', false), node('/r/zeta', true), node('/r/a10.txt', false), node('/r/a2.txt', false), node('/r/alpha', true)]);
		deepStrictEqual(sorted.map(n => n.name), ['alpha', 'zeta', 'a2.txt', 'a10.txt', 'b.txt']);
	});

	test('getChildren lists a folder, sorted and filtered', async () => {
		await fileService.createFolder(URI.parse('mem:/root/src'));
		await fileService.createFolder(URI.parse('mem:/root/.git'));
		await fileService.writeFile(URI.parse('mem:/root/readme.md'), VSBuffer.fromString(''));
		await fileService.writeFile(URI.parse('mem:/root/.DS_Store'), VSBuffer.fromString(''));
		const source = new MapoExplorerDataSource(fileService, n => n.name === '.git' || n.name === '.DS_Store');
		strictEqual(source.hasChildren(node('/root', true)), true);
		strictEqual(source.hasChildren(node('/root/readme.md', false)), false);
		const children = await source.getChildren(node('/root', true));
		deepStrictEqual(children.map(c => [c.name, c.isDirectory]), [['src', true], ['readme.md', false]]);
	});

	test('getChildren returns empty for a missing folder', async () => {
		const source = new MapoExplorerDataSource(fileService, () => false);
		deepStrictEqual(await source.getChildren(node('/nope', true)), []);
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --run src/vs/workbench/contrib/mapo/test/browser/mapoExplorerDataSource.test.ts`
Expected: FAIL, module not found.

- [ ] **Step 3: Write the implementation**

```ts
// src/vs/workbench/contrib/mapo/browser/mapoExplorerDataSource.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { IAsyncDataSource } from '../../../../base/browser/ui/tree/tree.js';
import { compareFileNames } from '../../../../base/common/comparers.js';
import { URI } from '../../../../base/common/uri.js';
import { IFileService, IFileStat } from '../../../../platform/files/common/files.js';

export interface IFileNode {
	readonly resource: URI;
	readonly name: string;
	readonly isDirectory: boolean;
}

export function sortFileNodes(nodes: IFileNode[]): IFileNode[] {
	return nodes.slice().sort((a, b) => {
		if (a.isDirectory !== b.isDirectory) {
			return a.isDirectory ? -1 : 1;
		}
		return compareFileNames(a.name, b.name);
	});
}

export class MapoExplorerDataSource implements IAsyncDataSource<IFileNode, IFileNode> {

	constructor(
		private readonly fileService: IFileService,
		private readonly isExcluded: (node: IFileNode) => boolean,
	) { }

	hasChildren(element: IFileNode): boolean {
		return element.isDirectory;
	}

	async getChildren(element: IFileNode): Promise<IFileNode[]> {
		let stat: IFileStat;
		try {
			stat = await this.fileService.resolve(element.resource);
		} catch {
			return [];
		}
		const nodes = (stat.children ?? [])
			.map(child => ({ resource: child.resource, name: child.name, isDirectory: child.isDirectory }))
			.filter(node => !this.isExcluded(node));
		return sortFileNodes(nodes);
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --run src/vs/workbench/contrib/mapo/test/browser/mapoExplorerDataSource.test.ts`
Expected: 3 passing. If `compareFileNames` orders `a10.txt` before `a2.txt`, change the expected order in the test to match the numeric-aware behaviour VS Code uses (it should already be `a2.txt`, `a10.txt`).

- [ ] **Step 5: Lint and commit**

```bash
npx eslint src/vs/workbench/contrib/mapo
git add src/vs/workbench/contrib/mapo
git commit -m "mapo: add explorer data source

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Workspace service

**Files:**
- Create: `src/vs/workbench/contrib/mapo/browser/mapoWorkspaceService.ts`
- Test: `src/vs/workbench/contrib/mapo/test/browser/mapoWorkspaceService.test.ts`

**Interfaces:**
- Consumes: Task 1 model, Task 2 `readGitBranch`.
- Produces:

```ts
export const IMapoWorkspaceService = createDecorator<IMapoWorkspaceService>('mapoWorkspaceService');
export type MapoTabStatus = 'waiting' | 'running' | 'idle' | 'exited' | 'none';
export interface IMapoWorkspaceInfo { status: MapoTabStatus; kind: MapoTabKind | undefined; cwd: string | undefined; branch: string | undefined; commandLine: string | undefined }
export interface IMapoWorkspaceService {
	readonly _serviceBrand: undefined;
	readonly workspaces: readonly IMapoWorkspace[];
	readonly activeWorkspace: IMapoWorkspace | undefined;
	readonly onDidChange: Event<void>;
	createWorkspace(name: string): Promise<IMapoWorkspace>;
	renameWorkspace(id: string, name: string): void;
	deleteWorkspace(id: string): Promise<void>;
	activateWorkspace(id: string): Promise<void>;
	createTab(workspaceId: string, kind: MapoTabKind, cwd: string): Promise<IMapoTab>;
	closeTab(tabId: string): void;
	getInstance(tabId: string): ITerminalInstance | undefined;
	getTabForInstance(instance: ITerminalInstance): { workspace: IMapoWorkspace; tab: IMapoTab } | undefined;
	getWorkspaceInfo(workspaceId: string): IMapoWorkspaceInfo;
	restore(): Promise<void>;
}
export class MapoWorkspaceService extends Disposable implements IMapoWorkspaceService
```

- [ ] **Step 1: Write the failing test**

```ts
// src/vs/workbench/contrib/mapo/test/browser/mapoWorkspaceService.test.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { deepStrictEqual, ok, strictEqual } from 'assert';
import { Emitter, Event } from '../../../../../base/common/event.js';
import { DisposableStore } from '../../../../../base/common/lifecycle.js';
import { URI } from '../../../../../base/common/uri.js';
import { mock } from '../../../../../base/test/common/mock.js';
import { ensureNoDisposablesAreLeakedInTestSuite } from '../../../../../base/test/common/utils.js';
import { FileService } from '../../../../../platform/files/common/fileService.js';
import { InMemoryFileSystemProvider } from '../../../../../platform/files/common/inMemoryFilesystemProvider.js';
import { NullLogService } from '../../../../../platform/log/common/log.js';
import { StorageScope } from '../../../../../platform/storage/common/storage.js';
import { TerminalCapabilityStore } from '../../../../../platform/terminal/common/capabilities/terminalCapabilityStore.js';
import { TerminalLocation } from '../../../../../platform/terminal/common/terminal.js';
import { TestStorageService } from '../../../../test/common/workbenchTestServices.js';
import { TestLifecycleService } from '../../../../test/browser/workbenchTestServices.js';
import { ICreateTerminalOptions, ITerminalEditorService, ITerminalInstance, ITerminalService, TerminalEditorLocation } from '../../../terminal/browser/terminal.js';
import { ITerminalStatus, ITerminalStatusList } from '../../../terminal/browser/terminalStatusList.js';
import { IEditorService } from '../../../../services/editor/common/editorService.js';
import { MAPO_STORAGE_KEY } from '../../common/mapoWorkspace.js';
import { MapoWorkspaceService } from '../../browser/mapoWorkspaceService.js';

class FakeInstance extends mock<ITerminalInstance>() {
	private static nextId = 1;
	override readonly instanceId = FakeInstance.nextId++;
	override readonly capabilities = new TerminalCapabilityStore();
	private readonly _onDisposed = new Emitter<ITerminalInstance>();
	override readonly onDisposed = this._onDisposed.event;
	override readonly onTitleChanged = Event.None;
	override readonly onDidFocus = Event.None;
	override readonly onDidBlur = Event.None;
	override readonly statusList: ITerminalStatusList = { onDidAddStatus: Event.None, onDidRemoveStatus: Event.None, onDidChangePrimaryStatus: Event.None, statuses: [], primary: undefined } as unknown as ITerminalStatusList;
	override title = 'zsh';
	focused = false;
	disposed = false;
	commands: string[] = [];
	override focus(): void { this.focused = true; }
	override async runCommand(command: string): Promise<void> { this.commands.push(command); }
	override dispose(): void {
		if (!this.disposed) {
			this.disposed = true;
			this._onDisposed.fire(this);
		}
		this.capabilities.dispose();
		this._onDisposed.dispose();
	}
}

class FakeTerminalService extends mock<ITerminalService>() {
	created: { options: ICreateTerminalOptions | undefined; instance: FakeInstance }[] = [];
	override readonly onDidChangeActiveInstance = Event.None;
	override activeInstance: ITerminalInstance | undefined = undefined;
	override async createTerminal(options?: ICreateTerminalOptions): Promise<ITerminalInstance> {
		const instance = new FakeInstance();
		this.created.push({ options, instance });
		return instance;
	}
}

class FakeTerminalEditorService extends mock<ITerminalEditorService>() {
	detached: ITerminalInstance[] = [];
	opened: { instance: ITerminalInstance; preserveFocus: boolean | undefined }[] = [];
	override readonly onDidFocusInstance = Event.None;
	override detachInstance(instance: ITerminalInstance): void { this.detached.push(instance); }
	override async openEditor(instance: ITerminalInstance, options?: TerminalEditorLocation): Promise<void> { this.opened.push({ instance, preserveFocus: options?.preserveFocus }); }
}

class FakeEditorService extends mock<IEditorService>() {
	closeCalls = 0;
	override getEditors() { return []; }
	override async closeEditors(): Promise<void> { this.closeCalls++; }
}

suite('Mapo - workspace service', () => {

	const disposables = ensureNoDisposablesAreLeakedInTestSuite();
	let storage: TestStorageService;
	let terminals: FakeTerminalService;
	let terminalEditors: FakeTerminalEditorService;
	let editors: FakeEditorService;
	let fileService: FileService;
	let service: MapoWorkspaceService;

	function createService(): MapoWorkspaceService {
		return disposables.add(new MapoWorkspaceService(storage, terminals, terminalEditors, editors, fileService, disposables.add(new TestLifecycleService()), new NullLogService()));
	}

	setup(() => {
		storage = disposables.add(new TestStorageService());
		terminals = new FakeTerminalService();
		terminalEditors = new FakeTerminalEditorService();
		editors = new FakeEditorService();
		fileService = disposables.add(new FileService(new NullLogService()));
		disposables.add(fileService.registerProvider('file', disposables.add(new InMemoryFileSystemProvider())));
		service = createService();
	});

	teardown(() => {
		for (const { instance } of terminals.created) {
			instance.dispose();
		}
	});

	test('create, rename, delete workspaces and persist', async () => {
		const a = await service.createWorkspace('A');
		strictEqual(service.activeWorkspace?.id, a.id);
		service.renameWorkspace(a.id, 'Alpha');
		strictEqual(service.workspaces[0].name, 'Alpha');
		const stored = storage.get(MAPO_STORAGE_KEY, StorageScope.APPLICATION);
		ok(stored?.includes('Alpha'));
		await service.deleteWorkspace(a.id);
		deepStrictEqual(service.workspaces, []);
		strictEqual(service.activeWorkspace, undefined);
	});

	test('state survives a new service instance', async () => {
		const a = await service.createWorkspace('A');
		await service.createTab(a.id, 'terminal', '/work');
		const again = createService();
		strictEqual(again.workspaces.length, 1);
		strictEqual(again.workspaces[0].tabs[0].cwd, '/work');
		strictEqual(again.activeWorkspace, undefined, 'restore() decides the active workspace');
	});

	test('createTab launches a terminal editor in the tab folder and runs claude for claude tabs', async () => {
		const a = await service.createWorkspace('A');
		const tab = await service.createTab(a.id, 'claude', '/proj');
		strictEqual(terminals.created.length, 1);
		strictEqual(terminals.created[0].options?.cwd, '/proj');
		strictEqual(terminals.created[0].options?.location, TerminalLocation.Editor);
		deepStrictEqual(terminals.created[0].instance.commands, ['claude']);
		strictEqual(service.getInstance(tab.id), terminals.created[0].instance);
		strictEqual(service.getTabForInstance(terminals.created[0].instance)?.tab.id, tab.id);
		strictEqual(service.workspaces[0].activeTabId, tab.id);
	});

	test('disposing an instance removes its tab', async () => {
		const a = await service.createWorkspace('A');
		const tab = await service.createTab(a.id, 'terminal', '/proj');
		terminals.created[0].instance.dispose();
		deepStrictEqual(service.workspaces[0].tabs, []);
		strictEqual(service.getInstance(tab.id), undefined);
	});

	test('closeTab disposes the instance', async () => {
		const a = await service.createWorkspace('A');
		const tab = await service.createTab(a.id, 'terminal', '/proj');
		service.closeTab(tab.id);
		strictEqual(terminals.created[0].instance.disposed, true);
		deepStrictEqual(service.workspaces[0].tabs, []);
	});

	test('switching workspaces detaches the old tabs and reopens the new ones', async () => {
		const a = await service.createWorkspace('A');
		await service.createTab(a.id, 'terminal', '/a');
		const b = await service.createWorkspace('B');
		await service.createTab(b.id, 'terminal', '/b');
		const [ta, tb] = terminals.created.map(c => c.instance);
		deepStrictEqual(terminalEditors.detached, [ta]);
		terminalEditors.detached = [];
		terminalEditors.opened = [];
		await service.activateWorkspace(a.id);
		deepStrictEqual(terminalEditors.detached, [tb]);
		strictEqual(terminalEditors.opened.length, 2, 'once with preserveFocus, once to focus the active tab');
		strictEqual(terminalEditors.opened[0].instance, ta);
		strictEqual(terminalEditors.opened[0].preserveFocus, true);
		strictEqual(terminalEditors.opened[1].preserveFocus, undefined);
		strictEqual(ta.focused, true);
		strictEqual(terminals.created.length, 2, 'no relaunch');
		ok(editors.closeCalls >= 1, 'file editors closed on switch');
	});

	test('restore relaunches the saved active workspace tabs lazily', async () => {
		const a = await service.createWorkspace('A');
		await service.createTab(a.id, 'terminal', '/a');
		const b = await service.createWorkspace('B');
		await service.createTab(b.id, 'claude', '/b');
		const again = createService();
		terminals.created = [];
		await again.restore();
		strictEqual(again.activeWorkspace?.id, b.id);
		strictEqual(terminals.created.length, 1, 'only the active workspace launches');
		strictEqual(terminals.created[0].options?.cwd, '/b');
		deepStrictEqual(terminals.created[0].instance.commands, ['claude']);
	});

	test('getWorkspaceInfo reports status, cwd and branch', async () => {
		await fileService.writeFile(URI.file('/repo/.git/HEAD'), (await import('../../../../../base/common/buffer.js')).VSBuffer.fromString('ref: refs/heads/main\n'));
		const a = await service.createWorkspace('A');
		strictEqual(service.getWorkspaceInfo(a.id).status, 'none');
		await service.createTab(a.id, 'terminal', '/repo');
		const info = service.getWorkspaceInfo(a.id);
		strictEqual(info.status, 'idle');
		strictEqual(info.cwd, '/repo');
		strictEqual(info.kind, 'terminal');
		await Event.toPromise(service.onDidChange);
		strictEqual(service.getWorkspaceInfo(a.id).branch, 'main');
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test.sh --run src/vs/workbench/contrib/mapo/test/browser/mapoWorkspaceService.test.ts`
Expected: FAIL, module `../../browser/mapoWorkspaceService.js` not found.

- [ ] **Step 3: Write the implementation**

```ts
// src/vs/workbench/contrib/mapo/browser/mapoWorkspaceService.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Emitter, Event } from '../../../../base/common/event.js';
import { Disposable, DisposableStore } from '../../../../base/common/lifecycle.js';
import { URI } from '../../../../base/common/uri.js';
import { IFileService } from '../../../../platform/files/common/files.js';
import { createDecorator } from '../../../../platform/instantiation/common/instantiation.js';
import { ILogService } from '../../../../platform/log/common/log.js';
import { IStorageService, StorageScope, StorageTarget } from '../../../../platform/storage/common/storage.js';
import { TerminalCapability } from '../../../../platform/terminal/common/capabilities/capabilities.js';
import { TerminalExitReason, TerminalLocation } from '../../../../platform/terminal/common/terminal.js';
import { EditorsOrder } from '../../../common/editor.js';
import { IEditorService } from '../../../services/editor/common/editorService.js';
import { ILifecycleService } from '../../../services/lifecycle/common/lifecycle.js';
import { ITerminalEditorService, ITerminalInstance, ITerminalService } from '../../terminal/browser/terminal.js';
import { TerminalEditorInput } from '../../terminal/browser/terminalEditorInput.js';
import { TerminalStatus } from '../../terminal/browser/terminalStatusList.js';
import { createTab, createWorkspace, IMapoState, IMapoTab, IMapoWorkspace, MAPO_STORAGE_KEY, MapoTabKind, parseState, serializeState } from '../common/mapoWorkspace.js';
import { readGitBranch } from './mapoGitBranch.js';

export const IMapoWorkspaceService = createDecorator<IMapoWorkspaceService>('mapoWorkspaceService');

export type MapoTabStatus = 'waiting' | 'running' | 'idle' | 'exited' | 'none';

export interface IMapoWorkspaceInfo {
	readonly status: MapoTabStatus;
	readonly kind: MapoTabKind | undefined;
	readonly cwd: string | undefined;
	readonly branch: string | undefined;
	readonly commandLine: string | undefined;
}

export interface IMapoWorkspaceService {
	readonly _serviceBrand: undefined;
	readonly workspaces: readonly IMapoWorkspace[];
	readonly activeWorkspace: IMapoWorkspace | undefined;
	readonly onDidChange: Event<void>;
	createWorkspace(name: string): Promise<IMapoWorkspace>;
	renameWorkspace(id: string, name: string): void;
	deleteWorkspace(id: string): Promise<void>;
	activateWorkspace(id: string): Promise<void>;
	createTab(workspaceId: string, kind: MapoTabKind, cwd: string): Promise<IMapoTab>;
	closeTab(tabId: string): void;
	getInstance(tabId: string): ITerminalInstance | undefined;
	getTabForInstance(instance: ITerminalInstance): { workspace: IMapoWorkspace; tab: IMapoTab } | undefined;
	getWorkspaceInfo(workspaceId: string): IMapoWorkspaceInfo;
	/** Called once at startup: closes restored editors and activates the saved workspace. */
	restore(): Promise<void>;
}

const CLAUDE_COMMAND = 'claude';

export class MapoWorkspaceService extends Disposable implements IMapoWorkspaceService {

	declare readonly _serviceBrand: undefined;

	private readonly _onDidChange = this._register(new Emitter<void>());
	readonly onDidChange = this._onDidChange.event;

	private readonly state: IMapoState;
	private readonly instances = new Map<string, ITerminalInstance>();
	private readonly instanceListeners = new Map<string, DisposableStore>();
	private readonly waitingTabs = new Set<string>();
	private readonly branches = new Map<string, string | undefined>();
	private queue: Promise<unknown> = Promise.resolve();
	private shuttingDown = false;

	constructor(
		@IStorageService private readonly storageService: IStorageService,
		@ITerminalService private readonly terminalService: ITerminalService,
		@ITerminalEditorService private readonly terminalEditorService: ITerminalEditorService,
		@IEditorService private readonly editorService: IEditorService,
		@IFileService private readonly fileService: IFileService,
		@ILifecycleService lifecycleService: ILifecycleService,
		@ILogService private readonly logService: ILogService,
	) {
		super();
		this.state = parseState(storageService.get(MAPO_STORAGE_KEY, StorageScope.APPLICATION));
		this._register(lifecycleService.onWillShutdown(() => { this.shuttingDown = true; }));
		this._register(this.terminalEditorService.onDidFocusInstance(instance => this.onInstanceFocused(instance)));
		this._register({ dispose: () => { for (const store of this.instanceListeners.values()) { store.dispose(); } this.instanceListeners.clear(); } });
	}

	get workspaces(): readonly IMapoWorkspace[] {
		return this.state.workspaces;
	}

	get activeWorkspace(): IMapoWorkspace | undefined {
		return this.getWorkspace(this.state.activeWorkspaceId);
	}

	private getWorkspace(id: string | undefined): IMapoWorkspace | undefined {
		return id === undefined ? undefined : this.state.workspaces.find(w => w.id === id);
	}

	private save(): void {
		this.storageService.store(MAPO_STORAGE_KEY, serializeState(this.state), StorageScope.APPLICATION, StorageTarget.MACHINE);
		this._onDidChange.fire();
	}

	private enqueue<T>(work: () => Promise<T>): Promise<T> {
		const run = this.queue.then(work, work);
		this.queue = run.catch(err => this.logService.error('[mapo] queued operation failed', err));
		return run;
	}

	// --- workspaces

	async createWorkspace(name: string): Promise<IMapoWorkspace> {
		const workspace = createWorkspace(name);
		this.state.workspaces.push(workspace);
		this.save();
		await this.activateWorkspace(workspace.id);
		return workspace;
	}

	renameWorkspace(id: string, name: string): void {
		const workspace = this.getWorkspace(id);
		if (workspace && name.trim()) {
			workspace.name = name.trim();
			this.save();
		}
	}

	deleteWorkspace(id: string): Promise<void> {
		return this.enqueue(async () => {
			const index = this.state.workspaces.findIndex(w => w.id === id);
			if (index === -1) {
				return;
			}
			const [workspace] = this.state.workspaces.splice(index, 1);
			for (const tab of workspace.tabs) {
				this.instances.get(tab.id)?.dispose(TerminalExitReason.User);
			}
			if (this.state.activeWorkspaceId === id) {
				this.state.activeWorkspaceId = undefined;
				const next = this.state.workspaces[Math.min(index, this.state.workspaces.length - 1)];
				if (next) {
					await this.doActivate(next.id);
				}
			}
			this.save();
		});
	}

	activateWorkspace(id: string): Promise<void> {
		return this.enqueue(() => this.doActivate(id));
	}

	private async doActivate(id: string): Promise<void> {
		const target = this.getWorkspace(id);
		if (!target || this.state.activeWorkspaceId === id) {
			return;
		}
		const previous = this.activeWorkspace;
		if (previous) {
			for (const tab of previous.tabs) {
				const instance = this.instances.get(tab.id);
				if (instance) {
					this.terminalEditorService.detachInstance(instance);
				}
			}
		}
		await this.closeFileEditors();
		this.state.activeWorkspaceId = id;
		for (const tab of target.tabs.slice()) {
			const instance = await this.ensureInstance(target, tab);
			if (instance) {
				await this.terminalEditorService.openEditor(instance, { preserveFocus: true });
			}
		}
		const activeTab = target.tabs.find(t => t.id === target.activeTabId) ?? target.tabs[0];
		const activeInstance = activeTab ? this.instances.get(activeTab.id) : undefined;
		if (activeInstance) {
			await this.terminalEditorService.openEditor(activeInstance);
			activeInstance.focus(true);
		}
		this.save();
	}

	private async closeFileEditors(): Promise<void> {
		const toClose = this.editorService.getEditors(EditorsOrder.SEQUENTIAL).filter(({ editor }) => !(editor instanceof TerminalEditorInput));
		if (toClose.length > 0) {
			await this.editorService.closeEditors(toClose);
		}
	}

	// --- tabs

	createTab(workspaceId: string, kind: MapoTabKind, cwd: string): Promise<IMapoTab> {
		return this.enqueue(async () => {
			const workspace = this.getWorkspace(workspaceId);
			if (!workspace) {
				throw new Error(`Unknown workspace ${workspaceId}`);
			}
			if (this.state.activeWorkspaceId !== workspaceId) {
				await this.doActivate(workspaceId);
			}
			const tab = createTab(kind, cwd);
			workspace.tabs.push(tab);
			workspace.activeTabId = tab.id;
			await this.ensureInstance(workspace, tab);
			this.save();
			return tab;
		});
	}

	closeTab(tabId: string): void {
		const instance = this.instances.get(tabId);
		if (instance) {
			instance.dispose(TerminalExitReason.User);
		} else {
			this.removeTab(tabId);
		}
	}

	getInstance(tabId: string): ITerminalInstance | undefined {
		return this.instances.get(tabId);
	}

	getTabForInstance(instance: ITerminalInstance): { workspace: IMapoWorkspace; tab: IMapoTab } | undefined {
		for (const workspace of this.state.workspaces) {
			for (const tab of workspace.tabs) {
				if (this.instances.get(tab.id) === instance) {
					return { workspace, tab };
				}
			}
		}
		return undefined;
	}

	private async ensureInstance(workspace: IMapoWorkspace, tab: IMapoTab): Promise<ITerminalInstance | undefined> {
		const existing = this.instances.get(tab.id);
		if (existing) {
			return existing;
		}
		let instance: ITerminalInstance;
		try {
			instance = await this.terminalService.createTerminal({ cwd: tab.cwd, location: TerminalLocation.Editor });
		} catch (err) {
			this.logService.error(`[mapo] failed to launch ${tab.kind} tab in ${tab.cwd}`, err);
			return undefined;
		}
		this.track(tab, instance);
		if (tab.kind === 'claude') {
			instance.runCommand(CLAUDE_COMMAND, true).catch(err => this.logService.error('[mapo] failed to start claude', err));
		}
		return instance;
	}

	private track(tab: IMapoTab, instance: ITerminalInstance): void {
		this.instances.set(tab.id, instance);
		const store = new DisposableStore();
		this.instanceListeners.set(tab.id, store);
		store.add(instance.onDisposed(() => this.onInstanceDisposed(tab.id)));
		store.add(instance.onTitleChanged(() => this._onDidChange.fire()));
		store.add(instance.onDidFocus(() => {
			this.waitingTabs.delete(tab.id);
			this._onDidChange.fire();
		}));
		store.add(instance.statusList.onDidAddStatus(status => {
			if (status.id === TerminalStatus.Bell) {
				this.waitingTabs.add(tab.id);
				this._onDidChange.fire();
			}
		}));
		const cwdDetection = instance.capabilities.get(TerminalCapability.CwdDetection);
		if (cwdDetection) {
			store.add(cwdDetection.onDidChangeCwd(cwd => this.onCwdChanged(cwd)));
		}
		const commandDetection = instance.capabilities.get(TerminalCapability.CommandDetection);
		if (commandDetection) {
			store.add(commandDetection.onCommandStarted(() => this._onDidChange.fire()));
			store.add(commandDetection.onCommandFinished(() => { this.waitingTabs.delete(tab.id); this._onDidChange.fire(); }));
		}
		store.add(instance.capabilities.onDidAddCapability(e => {
			if (e.id === TerminalCapability.CwdDetection) {
				store.add(e.capability.onDidChangeCwd(cwd => this.onCwdChanged(cwd)));
				this.onCwdChanged(e.capability.getCwd());
			} else if (e.id === TerminalCapability.CommandDetection) {
				store.add(e.capability.onCommandStarted(() => this._onDidChange.fire()));
				store.add(e.capability.onCommandFinished(() => { this.waitingTabs.delete(tab.id); this._onDidChange.fire(); }));
			}
		}));
	}

	private onInstanceDisposed(tabId: string): void {
		this.instances.delete(tabId);
		this.instanceListeners.get(tabId)?.dispose();
		this.instanceListeners.delete(tabId);
		this.waitingTabs.delete(tabId);
		if (this.shuttingDown) {
			return;
		}
		this.removeTab(tabId);
	}

	private removeTab(tabId: string): void {
		for (const workspace of this.state.workspaces) {
			const index = workspace.tabs.findIndex(t => t.id === tabId);
			if (index !== -1) {
				workspace.tabs.splice(index, 1);
				if (workspace.activeTabId === tabId) {
					workspace.activeTabId = workspace.tabs[0]?.id;
				}
				break;
			}
		}
		this.save();
	}

	private onInstanceFocused(instance: ITerminalInstance): void {
		const found = this.getTabForInstance(instance);
		if (found && found.workspace.activeTabId !== found.tab.id) {
			found.workspace.activeTabId = found.tab.id;
			this.save();
		}
	}

	private onCwdChanged(cwd: string): void {
		this.refreshBranch(cwd);
		this._onDidChange.fire();
	}

	// --- info

	getWorkspaceInfo(workspaceId: string): IMapoWorkspaceInfo {
		const workspace = this.getWorkspace(workspaceId);
		const tab = workspace ? (workspace.tabs.find(t => t.id === workspace.activeTabId) ?? workspace.tabs[0]) : undefined;
		if (!workspace || !tab) {
			return { status: 'none', kind: undefined, cwd: undefined, branch: undefined, commandLine: undefined };
		}
		const instance = this.instances.get(tab.id);
		const cwd = instance?.capabilities.get(TerminalCapability.CwdDetection)?.getCwd() || tab.cwd;
		if (!this.branches.has(cwd)) {
			this.refreshBranch(cwd);
		}
		const commandLine = instance?.capabilities.get(TerminalCapability.CommandDetection)?.executingCommand;
		let status: MapoTabStatus;
		if (!instance) {
			status = 'exited';
		} else if (this.waitingTabs.has(tab.id)) {
			status = 'waiting';
		} else if (commandLine) {
			status = 'running';
		} else {
			status = 'idle';
		}
		return { status, kind: tab.kind, cwd, branch: this.branches.get(cwd), commandLine };
	}

	private refreshBranch(cwd: string): void {
		this.branches.set(cwd, undefined);
		readGitBranch(this.fileService, URI.file(cwd)).then(branch => {
			if (this._store.isDisposed) {
				return;
			}
			this.branches.set(cwd, branch);
			this._onDidChange.fire();
		}, err => this.logService.warn('[mapo] failed to read git branch', err));
	}

	// --- startup

	async restore(): Promise<void> {
		const id = this.state.activeWorkspaceId ?? this.state.workspaces[0]?.id;
		this.state.activeWorkspaceId = undefined;
		const restored = this.editorService.getEditors(EditorsOrder.SEQUENTIAL);
		if (restored.length > 0) {
			await this.editorService.closeEditors(restored);
		}
		if (id) {
			await this.activateWorkspace(id);
		} else {
			this._onDidChange.fire();
		}
	}
}
```

Notes for the implementer:
- `TestLifecycleService` lives in `src/vs/workbench/test/browser/workbenchTestServices.ts`; if its constructor needs arguments, check the file and adapt the test's `createService()`.
- `ITerminalStatusList` / `ITerminalStatus` are exported from `terminalStatusList.ts`; if `ITerminalStatus` is unused in the test, drop the import (eslint fails on unused imports).
- `TerminalCapabilityStore` is in `src/vs/platform/terminal/common/capabilities/terminalCapabilityStore.ts` and is disposable.
- The `mock<T>()` helper returns a class whose methods throw when called unless overridden; if the service calls something the fakes do not override, the test fails with "Method not implemented" and tells you which method to add.
- The `getWorkspaceInfo` test waits for `onDidChange` after `createTab`; if the branch resolves before the wait (race), replace that wait with polling: `while (service.getWorkspaceInfo(a.id).branch === undefined) { await timeout(5); }` using `timeout` from `base/common/async.js`.

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test.sh --run src/vs/workbench/contrib/mapo/test/browser/mapoWorkspaceService.test.ts`
Expected: 8 passing.

- [ ] **Step 5: Lint and commit**

```bash
npx eslint src/vs/workbench/contrib/mapo
git add src/vs/workbench/contrib/mapo
git commit -m "mapo: add workspace service with terminal tab lifecycle

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Workspaces view, actions, chrome defaults, startup wiring

**Files:**
- Create: `src/vs/workbench/contrib/mapo/browser/mapoViews.ts` (ids shared by views and actions)
- Create: `src/vs/workbench/contrib/mapo/browser/mapoWorkspacesView.ts`
- Create: `src/vs/workbench/contrib/mapo/browser/mapoActions.ts`
- Create: `src/vs/workbench/contrib/mapo/browser/mapoStartup.ts`
- Create: `src/vs/workbench/contrib/mapo/browser/mapo.contribution.ts`
- Create: `src/vs/workbench/contrib/mapo/browser/media/mapo.css`
- Create: `scripts/mapo.sh`
- Modify: `src/vs/workbench/workbench.common.main.ts` (add one import next to the `timeline` imports, around line 444)

**Interfaces:**
- Consumes: `IMapoWorkspaceService`, `MapoWorkspaceService`, `IMapoWorkspaceInfo` (Task 4).
- Produces: `MAPO_WORKSPACES_CONTAINER_ID = 'workbench.view.mapoWorkspaces'`, `MAPO_WORKSPACES_VIEW_ID = 'mapo.workspacesView'`, `MAPO_EXPLORER_CONTAINER_ID = 'workbench.view.mapoExplorer'`, `MAPO_EXPLORER_VIEW_ID = 'mapo.explorerView'`, `MapoWorkspaceContextMenu: MenuId`. Task 6 registers the explorer view into `MAPO_EXPLORER_CONTAINER_ID`.

- [ ] **Step 1: Shared ids**

```ts
// src/vs/workbench/contrib/mapo/browser/mapoViews.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { MenuId } from '../../../../platform/actions/common/actions.js';

export const MAPO_WORKSPACES_CONTAINER_ID = 'workbench.view.mapoWorkspaces';
export const MAPO_WORKSPACES_VIEW_ID = 'mapo.workspacesView';
export const MAPO_EXPLORER_CONTAINER_ID = 'workbench.view.mapoExplorer';
export const MAPO_EXPLORER_VIEW_ID = 'mapo.explorerView';

export const MapoWorkspaceContextMenu = new MenuId('MapoWorkspaceContext');

export const enum MapoCommandId {
	NewWorkspace = 'mapo.workspace.new',
	RenameWorkspace = 'mapo.workspace.rename',
	DeleteWorkspace = 'mapo.workspace.delete',
	NextWorkspace = 'mapo.workspace.next',
	PreviousWorkspace = 'mapo.workspace.previous',
	NewTerminalTab = 'mapo.tab.newTerminal',
	NewClaudeTab = 'mapo.tab.newClaude',
}
```

- [ ] **Step 2: Workspaces view**

```ts
// src/vs/workbench/contrib/mapo/browser/mapoWorkspacesView.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { $, append } from '../../../../base/browser/dom.js';
import { IListContextMenuEvent, IListRenderer, IListVirtualDelegate } from '../../../../base/browser/ui/list/list.js';
import { tildify } from '../../../../base/common/labels.js';
import { localize } from '../../../../nls.js';
import { IConfigurationService } from '../../../../platform/configuration/common/configuration.js';
import { IContextKeyService } from '../../../../platform/contextkey/common/contextkey.js';
import { IContextMenuService } from '../../../../platform/contextview/browser/contextView.js';
import { IHoverService } from '../../../../platform/hover/browser/hover.js';
import { IInstantiationService } from '../../../../platform/instantiation/common/instantiation.js';
import { IKeybindingService } from '../../../../platform/keybinding/common/keybinding.js';
import { WorkbenchList } from '../../../../platform/list/browser/listService.js';
import { IOpenerService } from '../../../../platform/opener/common/opener.js';
import { IThemeService } from '../../../../platform/theme/common/themeService.js';
import { ViewPane } from '../../../browser/parts/views/viewPane.js';
import { IViewletViewOptions } from '../../../browser/parts/views/viewsViewlet.js';
import { IViewDescriptorService } from '../../../common/views.js';
import { IPathService } from '../../../services/path/common/pathService.js';
import { IMapoWorkspace } from '../common/mapoWorkspace.js';
import { MapoWorkspaceContextMenu } from './mapoViews.js';
import { IMapoWorkspaceInfo, IMapoWorkspaceService } from './mapoWorkspaceService.js';

interface IWorkspaceTemplate {
	readonly root: HTMLElement;
	readonly name: HTMLElement;
	readonly status: HTMLElement;
	readonly detail: HTMLElement;
}

export function describeStatus(info: IMapoWorkspaceInfo): string {
	const who = info.kind === 'claude' ? localize('mapo.claude', "Claude") : localize('mapo.terminal', "Terminal");
	switch (info.status) {
		case 'waiting': return localize('mapo.status.waiting', "{0} is waiting for your input", who);
		case 'running': return info.kind === 'claude' ? localize('mapo.status.claudeRunning', "Claude is running") : localize('mapo.status.running', "Running: {0}", info.commandLine ?? '');
		case 'idle': return localize('mapo.status.idle', "Idle");
		case 'exited': return localize('mapo.status.exited', "Exited");
		case 'none': return localize('mapo.status.none', "No tabs");
	}
}

class WorkspaceDelegate implements IListVirtualDelegate<IMapoWorkspace> {
	getHeight(): number { return 64; }
	getTemplateId(): string { return WorkspaceRenderer.ID; }
}

class WorkspaceRenderer implements IListRenderer<IMapoWorkspace, IWorkspaceTemplate> {

	static readonly ID = 'mapoWorkspace';
	readonly templateId = WorkspaceRenderer.ID;

	constructor(
		private readonly mapo: IMapoWorkspaceService,
		private readonly userHome: string | undefined,
	) { }

	renderTemplate(container: HTMLElement): IWorkspaceTemplate {
		const root = append(container, $('.mapo-workspace'));
		const name = append(root, $('.mapo-workspace-name'));
		const status = append(root, $('.mapo-workspace-status'));
		const detail = append(root, $('.mapo-workspace-detail'));
		return { root, name, status, detail };
	}

	renderElement(workspace: IMapoWorkspace, _index: number, template: IWorkspaceTemplate): void {
		const info = this.mapo.getWorkspaceInfo(workspace.id);
		template.name.textContent = workspace.name;
		template.status.textContent = describeStatus(info);
		template.root.classList.toggle('waiting', info.status === 'waiting');
		const folder = info.cwd ? (this.userHome ? tildify(info.cwd, this.userHome) : info.cwd) : '';
		template.detail.textContent = info.branch ? `${info.branch} · ${folder}` : folder;
		template.detail.title = info.cwd ?? '';
	}

	disposeTemplate(): void { }
}

export class MapoWorkspacesView extends ViewPane {

	private list: WorkbenchList<IMapoWorkspace> | undefined;

	constructor(
		options: IViewletViewOptions,
		@IKeybindingService keybindingService: IKeybindingService,
		@IContextMenuService contextMenuService: IContextMenuService,
		@IConfigurationService configurationService: IConfigurationService,
		@IContextKeyService contextKeyService: IContextKeyService,
		@IViewDescriptorService viewDescriptorService: IViewDescriptorService,
		@IInstantiationService instantiationService: IInstantiationService,
		@IOpenerService openerService: IOpenerService,
		@IThemeService themeService: IThemeService,
		@IHoverService hoverService: IHoverService,
		@IPathService private readonly pathService: IPathService,
		@IMapoWorkspaceService private readonly mapo: IMapoWorkspaceService,
	) {
		super(options, keybindingService, contextMenuService, configurationService, contextKeyService, viewDescriptorService, instantiationService, openerService, themeService, hoverService);
		this._register(this.mapo.onDidChange(() => {
			this._onDidChangeViewWelcomeState.fire();
			this.refresh();
		}));
	}

	override shouldShowWelcome(): boolean {
		return this.mapo.workspaces.length === 0;
	}

	protected override renderBody(container: HTMLElement): void {
		super.renderBody(container);
		container.classList.add('mapo-workspaces');
		const renderer = new WorkspaceRenderer(this.mapo, this.pathService.resolvedUserHome?.fsPath);
		this.list = this._register(this.instantiationService.createInstance(WorkbenchList<IMapoWorkspace>, 'MapoWorkspaces', container, new WorkspaceDelegate(), [renderer], {
			identityProvider: { getId: (workspace: IMapoWorkspace) => workspace.id },
			accessibilityProvider: {
				getAriaLabel: (workspace: IMapoWorkspace) => workspace.name,
				getWidgetAriaLabel: () => localize('mapo.workspaces', "Workspaces"),
			},
			multipleSelectionSupport: false,
			openOnSingleClick: true,
			overrideStyles: this.getLocationBasedColors().listOverrideStyles,
		}));
		this._register(this.list.onDidOpen(e => {
			if (e.element) {
				this.mapo.activateWorkspace(e.element.id);
			}
		}));
		this._register(this.list.onContextMenu(e => this.onContextMenu(e)));
		this.refresh();
	}

	protected override layoutBody(height: number, width: number): void {
		super.layoutBody(height, width);
		this.list?.layout(height, width);
	}

	private refresh(): void {
		if (!this.list) {
			return;
		}
		const workspaces = [...this.mapo.workspaces];
		this.list.splice(0, this.list.length, workspaces);
		const activeIndex = workspaces.findIndex(w => w.id === this.mapo.activeWorkspace?.id);
		this.list.setSelection(activeIndex === -1 ? [] : [activeIndex]);
	}

	private onContextMenu(e: IListContextMenuEvent<IMapoWorkspace>): void {
		const workspace = e.element;
		if (!workspace) {
			return;
		}
		this.contextMenuService.showContextMenu({
			menuId: MapoWorkspaceContextMenu,
			menuActionOptions: { shouldForwardArgs: true },
			contextKeyService: this.list?.contextKeyService,
			getAnchor: () => e.anchor,
			getActionsContext: () => workspace.id,
		});
	}
}
```

- [ ] **Step 3: Actions**

```ts
// src/vs/workbench/contrib/mapo/browser/mapoActions.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Codicon } from '../../../../base/common/codicons.js';
import { KeyCode, KeyMod } from '../../../../base/common/keyCodes.js';
import { URI } from '../../../../base/common/uri.js';
import { localize, localize2 } from '../../../../nls.js';
import { Action2, MenuId, registerAction2 } from '../../../../platform/actions/common/actions.js';
import { ContextKeyExpr } from '../../../../platform/contextkey/common/contextkey.js';
import { IDialogService, IFileDialogService } from '../../../../platform/dialogs/common/dialogs.js';
import { ServicesAccessor } from '../../../../platform/instantiation/common/instantiation.js';
import { KeybindingWeight } from '../../../../platform/keybinding/common/keybindingsRegistry.js';
import { IQuickInputService } from '../../../../platform/quickinput/common/quickInput.js';
import { IMapoWorkspace, MapoTabKind } from '../common/mapoWorkspace.js';
import { MAPO_WORKSPACES_VIEW_ID, MapoCommandId, MapoWorkspaceContextMenu } from './mapoViews.js';
import { IMapoWorkspaceService } from './mapoWorkspaceService.js';

const inWorkspacesView = ContextKeyExpr.equals('view', MAPO_WORKSPACES_VIEW_ID);

function resolveWorkspace(mapo: IMapoWorkspaceService, workspaceId: unknown): IMapoWorkspace | undefined {
	if (typeof workspaceId === 'string') {
		return mapo.workspaces.find(w => w.id === workspaceId);
	}
	return mapo.activeWorkspace;
}

async function pickFolder(fileDialogService: IFileDialogService, workspace: IMapoWorkspace | undefined): Promise<string | undefined> {
	const lastCwd = workspace?.tabs.at(-1)?.cwd;
	const defaultUri = lastCwd ? URI.file(lastCwd) : await fileDialogService.defaultFolderPath();
	const picked = await fileDialogService.showOpenDialog({
		title: localize('mapo.pickFolder', "Choose the folder for the new tab"),
		openLabel: localize('mapo.pickFolder.open', "Use Folder"),
		canSelectFiles: false,
		canSelectFolders: true,
		canSelectMany: false,
		defaultUri,
	});
	return picked?.[0]?.fsPath;
}

async function newTab(accessor: ServicesAccessor, kind: MapoTabKind, workspaceId: unknown): Promise<void> {
	const mapo = accessor.get(IMapoWorkspaceService);
	const fileDialogService = accessor.get(IFileDialogService);
	const quickInputService = accessor.get(IQuickInputService);
	let workspace = resolveWorkspace(mapo, workspaceId);
	if (!workspace) {
		const name = await quickInputService.input({ prompt: localize('mapo.firstWorkspaceName', "Name for your first workspace") });
		if (!name?.trim()) {
			return;
		}
		workspace = await mapo.createWorkspace(name.trim());
	}
	const cwd = await pickFolder(fileDialogService, workspace);
	if (cwd) {
		await mapo.createTab(workspace.id, kind, cwd);
	}
}

registerAction2(class extends Action2 {
	constructor() {
		super({
			id: MapoCommandId.NewWorkspace,
			title: localize2('mapo.newWorkspace', "New Workspace"),
			icon: Codicon.add,
			f1: true,
			menu: [{ id: MenuId.ViewTitle, group: 'navigation', order: 1, when: inWorkspacesView }],
		});
	}
	async run(accessor: ServicesAccessor): Promise<void> {
		const mapo = accessor.get(IMapoWorkspaceService);
		const quickInputService = accessor.get(IQuickInputService);
		const name = await quickInputService.input({ prompt: localize('mapo.workspaceName', "Workspace name"), placeHolder: localize('mapo.workspaceName.placeholder', "e.g. Mesh") });
		if (name?.trim()) {
			await mapo.createWorkspace(name.trim());
		}
	}
});

registerAction2(class extends Action2 {
	constructor() {
		super({
			id: MapoCommandId.NewTerminalTab,
			title: localize2('mapo.newTerminalTab', "New Terminal Tab"),
			icon: Codicon.terminal,
			f1: true,
			menu: [
				{ id: MenuId.ViewTitle, group: 'navigation', order: 2, when: inWorkspacesView },
				{ id: MapoWorkspaceContextMenu, group: '1_tabs', order: 1 },
			],
		});
	}
	run(accessor: ServicesAccessor, workspaceId?: unknown): Promise<void> {
		return newTab(accessor, 'terminal', workspaceId);
	}
});

registerAction2(class extends Action2 {
	constructor() {
		super({
			id: MapoCommandId.NewClaudeTab,
			title: localize2('mapo.newClaudeTab', "New Claude Tab"),
			icon: Codicon.sparkle,
			f1: true,
			menu: [
				{ id: MenuId.ViewTitle, group: 'navigation', order: 3, when: inWorkspacesView },
				{ id: MapoWorkspaceContextMenu, group: '1_tabs', order: 2 },
			],
		});
	}
	run(accessor: ServicesAccessor, workspaceId?: unknown): Promise<void> {
		return newTab(accessor, 'claude', workspaceId);
	}
});

registerAction2(class extends Action2 {
	constructor() {
		super({
			id: MapoCommandId.RenameWorkspace,
			title: localize2('mapo.renameWorkspace', "Rename Workspace"),
			f1: true,
			menu: [{ id: MapoWorkspaceContextMenu, group: '2_manage', order: 1 }],
		});
	}
	async run(accessor: ServicesAccessor, workspaceId?: unknown): Promise<void> {
		const mapo = accessor.get(IMapoWorkspaceService);
		const quickInputService = accessor.get(IQuickInputService);
		const workspace = resolveWorkspace(mapo, workspaceId);
		if (!workspace) {
			return;
		}
		const name = await quickInputService.input({ prompt: localize('mapo.renamePrompt', "New name"), value: workspace.name });
		if (name?.trim()) {
			mapo.renameWorkspace(workspace.id, name.trim());
		}
	}
});

registerAction2(class extends Action2 {
	constructor() {
		super({
			id: MapoCommandId.DeleteWorkspace,
			title: localize2('mapo.deleteWorkspace', "Delete Workspace"),
			f1: true,
			menu: [{ id: MapoWorkspaceContextMenu, group: '2_manage', order: 2 }],
		});
	}
	async run(accessor: ServicesAccessor, workspaceId?: unknown): Promise<void> {
		const mapo = accessor.get(IMapoWorkspaceService);
		const dialogService = accessor.get(IDialogService);
		const workspace = resolveWorkspace(mapo, workspaceId);
		if (!workspace) {
			return;
		}
		const { confirmed } = await dialogService.confirm({
			type: 'warning',
			message: localize('mapo.deleteConfirm', "Delete workspace '{0}'?", workspace.name),
			detail: localize('mapo.deleteDetail', "All {0} tab(s) in it will be closed.", workspace.tabs.length),
			primaryButton: localize('mapo.delete', "Delete"),
		});
		if (confirmed) {
			await mapo.deleteWorkspace(workspace.id);
		}
	}
});

function cycle(accessor: ServicesAccessor, delta: 1 | -1): Promise<void> {
	const mapo = accessor.get(IMapoWorkspaceService);
	const workspaces = mapo.workspaces;
	if (workspaces.length === 0) {
		return Promise.resolve();
	}
	const current = workspaces.findIndex(w => w.id === mapo.activeWorkspace?.id);
	const next = workspaces[(current + delta + workspaces.length) % workspaces.length];
	return mapo.activateWorkspace(next.id);
}

registerAction2(class extends Action2 {
	constructor() {
		super({
			id: MapoCommandId.NextWorkspace,
			title: localize2('mapo.nextWorkspace', "Next Workspace"),
			f1: true,
			keybinding: { primary: KeyMod.CtrlCmd | KeyMod.WinCtrl | KeyCode.DownArrow, weight: KeybindingWeight.WorkbenchContrib },
		});
	}
	run(accessor: ServicesAccessor): Promise<void> { return cycle(accessor, 1); }
});

registerAction2(class extends Action2 {
	constructor() {
		super({
			id: MapoCommandId.PreviousWorkspace,
			title: localize2('mapo.previousWorkspace', "Previous Workspace"),
			f1: true,
			keybinding: { primary: KeyMod.CtrlCmd | KeyMod.WinCtrl | KeyCode.UpArrow, weight: KeybindingWeight.WorkbenchContrib },
		});
	}
	run(accessor: ServicesAccessor): Promise<void> { return cycle(accessor, -1); }
});
```

- [ ] **Step 4: Startup contribution**

```ts
// src/vs/workbench/contrib/mapo/browser/mapoStartup.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { ILogService } from '../../../../platform/log/common/log.js';
import { IWorkbenchContribution } from '../../../common/contributions.js';
import { IWorkbenchLayoutService, Parts } from '../../../services/layout/browser/layoutService.js';
import { IViewsService } from '../../../services/views/common/viewsService.js';
import { MAPO_EXPLORER_VIEW_ID, MAPO_WORKSPACES_CONTAINER_ID } from './mapoViews.js';
import { IMapoWorkspaceService } from './mapoWorkspaceService.js';

export class MapoStartupContribution implements IWorkbenchContribution {

	static readonly ID = 'workbench.contrib.mapoStartup';

	constructor(
		@IWorkbenchLayoutService private readonly layoutService: IWorkbenchLayoutService,
		@IViewsService private readonly viewsService: IViewsService,
		@IMapoWorkspaceService private readonly mapo: IMapoWorkspaceService,
		@ILogService private readonly logService: ILogService,
	) {
		this.run().catch(err => this.logService.error('[mapo] startup failed', err));
	}

	private async run(): Promise<void> {
		this.layoutService.setPartHidden(true, Parts.PANEL_PART);
		this.layoutService.setPartHidden(false, Parts.AUXILIARYBAR_PART);
		await this.viewsService.openViewContainer(MAPO_WORKSPACES_CONTAINER_ID);
		await this.viewsService.openView(MAPO_EXPLORER_VIEW_ID, false);
		await this.mapo.restore();
	}
}
```

- [ ] **Step 5: Contribution file, CSS, main import, launch script**

```ts
// src/vs/workbench/contrib/mapo/browser/mapo.contribution.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import './media/mapo.css';
import { Codicon } from '../../../../base/common/codicons.js';
import { localize, localize2 } from '../../../../nls.js';
import { Extensions as ConfigurationExtensions, IConfigurationRegistry } from '../../../../platform/configuration/common/configurationRegistry.js';
import { SyncDescriptor } from '../../../../platform/instantiation/common/descriptors.js';
import { InstantiationType, registerSingleton } from '../../../../platform/instantiation/common/extensions.js';
import { Registry } from '../../../../platform/registry/common/platform.js';
import { ViewPaneContainer } from '../../../browser/parts/views/viewPaneContainer.js';
import { registerWorkbenchContribution2, WorkbenchPhase } from '../../../common/contributions.js';
import { Extensions as ViewExtensions, IViewContainersRegistry, IViewsRegistry, ViewContainerLocation } from '../../../common/views.js';
import './mapoActions.js';
import { MapoStartupContribution } from './mapoStartup.js';
import { MAPO_EXPLORER_CONTAINER_ID, MAPO_WORKSPACES_CONTAINER_ID, MAPO_WORKSPACES_VIEW_ID, MapoCommandId } from './mapoViews.js';
import { IMapoWorkspaceService, MapoWorkspaceService } from './mapoWorkspaceService.js';
import { MapoWorkspacesView } from './mapoWorkspacesView.js';

registerSingleton(IMapoWorkspaceService, MapoWorkspaceService, InstantiationType.Delayed);

const viewContainersRegistry = Registry.as<IViewContainersRegistry>(ViewExtensions.ViewContainersRegistry);
const viewsRegistry = Registry.as<IViewsRegistry>(ViewExtensions.ViewsRegistry);

const workspacesContainer = viewContainersRegistry.registerViewContainer({
	id: MAPO_WORKSPACES_CONTAINER_ID,
	title: localize2('mapo.workspaces', "Workspaces"),
	icon: Codicon.layers,
	ctorDescriptor: new SyncDescriptor(ViewPaneContainer, [MAPO_WORKSPACES_CONTAINER_ID, { mergeViewWithContainerWhenSingleView: true }]),
	order: 0,
	hideIfEmpty: false,
}, ViewContainerLocation.Sidebar, { isDefault: true });

viewsRegistry.registerViews([{
	id: MAPO_WORKSPACES_VIEW_ID,
	name: localize2('mapo.workspaces', "Workspaces"),
	containerIcon: Codicon.layers,
	ctorDescriptor: new SyncDescriptor(MapoWorkspacesView),
	canToggleVisibility: false,
	canMoveView: false,
	order: 0,
}], workspacesContainer);

viewsRegistry.registerViewWelcomeContent(MAPO_WORKSPACES_VIEW_ID, {
	content: localize('mapo.welcome', "No workspaces yet.\n[New Workspace](command:{0})", MapoCommandId.NewWorkspace),
});

// The explorer view itself is registered in Task 6 (mapoExplorerView.ts); its container lives here.
export const mapoExplorerContainer = viewContainersRegistry.registerViewContainer({
	id: MAPO_EXPLORER_CONTAINER_ID,
	title: localize2('mapo.explorer', "Explorer"),
	icon: Codicon.files,
	ctorDescriptor: new SyncDescriptor(ViewPaneContainer, [MAPO_EXPLORER_CONTAINER_ID, { mergeViewWithContainerWhenSingleView: true }]),
	order: 0,
	hideIfEmpty: false,
}, ViewContainerLocation.AuxiliaryBar, { isDefault: true });

Registry.as<IConfigurationRegistry>(ConfigurationExtensions.Configuration).registerDefaultConfigurations([{
	overrides: {
		'workbench.activityBar.location': 'hidden',
		'workbench.statusBar.visible': false,
		'workbench.secondarySideBar.defaultVisibility': 'visible',
		'workbench.startupEditor': 'none',
		'workbench.editor.showTabs': 'multiple',
		'workbench.welcomePage.walkthroughs.openOnInstall': false,
		'terminal.integrated.defaultLocation': 'editor',
		'terminal.integrated.enableVisualBell': true,
		'terminal.integrated.enablePersistentSessions': false,
		'git.autoRepositoryDetection': true,
	},
}]);

registerWorkbenchContribution2(MapoStartupContribution.ID, MapoStartupContribution, WorkbenchPhase.AfterRestored);
```

```css
/* src/vs/workbench/contrib/mapo/browser/media/mapo.css */
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

.mapo-workspaces .monaco-list-row {
	padding: 0 8px;
}

.mapo-workspaces .mapo-workspace {
	display: flex;
	flex-direction: column;
	justify-content: center;
	height: 100%;
	gap: 2px;
	overflow: hidden;
}

.mapo-workspaces .mapo-workspace-name {
	font-weight: 600;
	white-space: nowrap;
	overflow: hidden;
	text-overflow: ellipsis;
}

.mapo-workspaces .mapo-workspace-status,
.mapo-workspaces .mapo-workspace-detail {
	font-size: 11px;
	opacity: 0.75;
	white-space: nowrap;
	overflow: hidden;
	text-overflow: ellipsis;
}

.mapo-workspaces .mapo-workspace.waiting .mapo-workspace-status {
	color: var(--vscode-notificationsWarningIcon-foreground);
	opacity: 1;
}

.mapo-explorer {
	display: flex;
	flex-direction: column;
	height: 100%;
}

.mapo-explorer .mapo-explorer-message {
	padding: 8px 20px;
	opacity: 0.8;
}

.mapo-explorer .mapo-explorer-message.hidden {
	display: none;
}

.mapo-explorer .mapo-explorer-tree {
	flex: 1;
	min-height: 0;
}
```

Add the import in `src/vs/workbench/workbench.common.main.ts` directly after the two `timeline` imports (around line 445):

```ts
//#region --- workbench contributions (mapo)
import './contrib/mapo/browser/mapo.contribution.js';
//#endregion
```

Launch script:

```bash
# scripts/mapo.sh
#!/usr/bin/env bash
# Launch the Mapo dev build without opening a folder (Mapo manages its own workspaces).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NAME=$(node -p "require('./product.json').nameLong")
EXE_NAME=$(node -p "require('./product.json').nameShort")
CODE="$ROOT/.build/electron/$NAME.app/Contents/MacOS/$EXE_NAME"
if [[ ! -x "$CODE" ]]; then
	echo "Electron not found at $CODE. Run: npm run electron" >&2
	exit 1
fi
export NODE_ENV=development
export VSCODE_DEV=1
export VSCODE_CLI=1
export ELECTRON_ENABLE_STACK_DUMPING=1
export ELECTRON_ENABLE_LOGGING=1
exec "$CODE" --disable-extension=vscode.vscode-api-tests "$@"
```

Run `chmod +x scripts/mapo.sh`.

- [ ] **Step 6: Type-check and lint**

Wait for the watcher, then `tail -3 .../watch-client.log` must show 0 errors. Run `npx eslint src/vs/workbench/contrib/mapo src/vs/workbench/workbench.common.main.ts`. Fix anything reported. Likely fixes: `IListRenderer` may require `disposeTemplate(template)` with a parameter; `WorkbenchList` constructor generic call may need `WorkbenchList<IMapoWorkspace>` cast as in `openEditorsView.ts:259-269`; `tildify` signature is `(path, userHome)`.

- [ ] **Step 7: Launch and check the shell**

Run in the background: `./scripts/mapo.sh --user-data-dir=/tmp/mapo-dev-profile 2>&1 | tail -50 > /private/tmp/claude-501/-Users-brunomazzardo-code-mapo/bf5c4805-19df-4815-9827-91eabfef56e7/scratchpad/mapo-run.log`.
Expected: the window opens with no activity bar, no status bar, "Workspaces" in the left side bar with the welcome text, an empty right side bar titled "Explorer" (container exists, view arrives in Task 6). The command palette lists "New Workspace". Creating a workspace and a terminal tab opens a terminal editor. Check `mapo-run.log` and the developer tools console (Help > Toggle Developer Tools) for `[mapo]` errors. Quit the app afterwards.

- [ ] **Step 8: Commit**

```bash
git add src/vs/workbench/contrib/mapo src/vs/workbench/workbench.common.main.ts scripts/mapo.sh
git commit -m "mapo: add workspaces view, actions, chrome defaults and startup wiring

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Explorer view following the focused terminal

**Files:**
- Create: `src/vs/workbench/contrib/mapo/browser/mapoExplorerView.ts`
- Modify: `src/vs/workbench/contrib/mapo/browser/mapo.contribution.ts` (register the view into `mapoExplorerContainer`)

**Interfaces:**
- Consumes: `IFileNode`, `MapoExplorerDataSource` (Task 3); `IMapoWorkspaceService.getTabForInstance` (Task 4); `MAPO_EXPLORER_VIEW_ID`, `mapoExplorerContainer` (Task 5).
- Produces: `MapoExplorerView` view pane.

- [ ] **Step 1: Explorer view**

```ts
// src/vs/workbench/contrib/mapo/browser/mapoExplorerView.ts
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { $, append } from '../../../../base/browser/dom.js';
import { IListVirtualDelegate } from '../../../../base/browser/ui/list/list.js';
import { ITreeNode, ITreeRenderer } from '../../../../base/browser/ui/tree/tree.js';
import { ThrottledDelayer } from '../../../../base/common/async.js';
import { FuzzyScore } from '../../../../base/common/filters.js';
import * as glob from '../../../../base/common/glob.js';
import { DisposableStore } from '../../../../base/common/lifecycle.js';
import { basename, isEqual, relativePath } from '../../../../base/common/resources.js';
import { URI } from '../../../../base/common/uri.js';
import { localize } from '../../../../nls.js';
import { IConfigurationService } from '../../../../platform/configuration/common/configuration.js';
import { IContextKeyService } from '../../../../platform/contextkey/common/contextkey.js';
import { IContextMenuService } from '../../../../platform/contextview/browser/contextView.js';
import { FileKind, IFileService } from '../../../../platform/files/common/files.js';
import { IHoverService } from '../../../../platform/hover/browser/hover.js';
import { IInstantiationService } from '../../../../platform/instantiation/common/instantiation.js';
import { IKeybindingService } from '../../../../platform/keybinding/common/keybinding.js';
import { ILabelService } from '../../../../platform/label/common/label.js';
import { WorkbenchAsyncDataTree } from '../../../../platform/list/browser/listService.js';
import { IOpenerService } from '../../../../platform/opener/common/opener.js';
import { TerminalCapability } from '../../../../platform/terminal/common/capabilities/capabilities.js';
import { IThemeService } from '../../../../platform/theme/common/themeService.js';
import { IResourceLabel, ResourceLabels } from '../../../browser/labels.js';
import { ViewPane } from '../../../browser/parts/views/viewPane.js';
import { IViewletViewOptions } from '../../../browser/parts/views/viewsViewlet.js';
import { IViewDescriptorService } from '../../../common/views.js';
import { ACTIVE_GROUP, IEditorService, SIDE_GROUP } from '../../../services/editor/common/editorService.js';
import { ITerminalInstance, ITerminalService } from '../../terminal/browser/terminal.js';
import { TerminalEditorInput } from '../../terminal/browser/terminalEditorInput.js';
import { IFileNode, MapoExplorerDataSource } from './mapoExplorerDataSource.js';
import { IMapoWorkspaceService } from './mapoWorkspaceService.js';

class FileNodeDelegate implements IListVirtualDelegate<IFileNode> {
	getHeight(): number { return 22; }
	getTemplateId(): string { return FileNodeRenderer.ID; }
}

class FileNodeRenderer implements ITreeRenderer<IFileNode, FuzzyScore, IResourceLabel> {

	static readonly ID = 'mapoFileNode';
	readonly templateId = FileNodeRenderer.ID;

	constructor(private readonly labels: ResourceLabels) { }

	renderTemplate(container: HTMLElement): IResourceLabel {
		return this.labels.create(container, { supportHighlights: true });
	}

	renderElement(node: ITreeNode<IFileNode, FuzzyScore>, _index: number, template: IResourceLabel): void {
		template.setFile(node.element.resource, {
			fileKind: node.element.isDirectory ? FileKind.FOLDER : FileKind.FILE,
			hidePath: true,
			fileDecorations: { colors: true, badges: true },
		});
	}

	disposeTemplate(template: IResourceLabel): void {
		template.dispose();
	}
}

export class MapoExplorerView extends ViewPane {

	private tree: WorkbenchAsyncDataTree<IFileNode, IFileNode, FuzzyScore> | undefined;
	private message: HTMLElement | undefined;
	private treeContainer: HTMLElement | undefined;
	private root: URI | undefined;
	private trackedInstance: ITerminalInstance | undefined;
	private excludeMatcher: glob.ParsedExpression = () => null;
	private readonly rootListeners = this._register(new DisposableStore());
	private readonly instanceListeners = this._register(new DisposableStore());
	private readonly refreshDelayer = this._register(new ThrottledDelayer<void>(300));

	constructor(
		options: IViewletViewOptions,
		@IKeybindingService keybindingService: IKeybindingService,
		@IContextMenuService contextMenuService: IContextMenuService,
		@IConfigurationService configurationService: IConfigurationService,
		@IContextKeyService contextKeyService: IContextKeyService,
		@IViewDescriptorService viewDescriptorService: IViewDescriptorService,
		@IInstantiationService instantiationService: IInstantiationService,
		@IOpenerService openerService: IOpenerService,
		@IThemeService themeService: IThemeService,
		@IHoverService hoverService: IHoverService,
		@IFileService private readonly fileService: IFileService,
		@IEditorService private readonly editorService: IEditorService,
		@ITerminalService private readonly terminalService: ITerminalService,
		@ILabelService private readonly labelService: ILabelService,
		@IMapoWorkspaceService private readonly mapo: IMapoWorkspaceService,
	) {
		super(options, keybindingService, contextMenuService, configurationService, contextKeyService, viewDescriptorService, instantiationService, openerService, themeService, hoverService);
	}

	protected override renderBody(container: HTMLElement): void {
		super.renderBody(container);
		container.classList.add('mapo-explorer', 'show-file-icons');
		this.message = append(container, $('.mapo-explorer-message.hidden'));
		this.treeContainer = append(container, $('.mapo-explorer-tree'));

		const labels = this._register(this.instantiationService.createInstance(ResourceLabels, { onDidChangeVisibility: this.onDidChangeBodyVisibility }));
		this.updateExcludes();
		const dataSource = new MapoExplorerDataSource(this.fileService, node => this.isExcluded(node));
		this.tree = this._register(this.instantiationService.createInstance(
			WorkbenchAsyncDataTree<IFileNode, IFileNode, FuzzyScore>,
			'MapoExplorer',
			this.treeContainer,
			new FileNodeDelegate(),
			[new FileNodeRenderer(labels)],
			dataSource,
			{
				identityProvider: { getId: (node: IFileNode) => node.resource.toString() },
				accessibilityProvider: {
					getAriaLabel: (node: IFileNode) => node.name,
					getWidgetAriaLabel: () => localize('mapo.explorer', "Explorer"),
				},
				multipleSelectionSupport: false,
				overrideStyles: this.getLocationBasedColors().listOverrideStyles,
			},
		));
		this._register(this.tree.onDidOpen(e => {
			if (e.element && !e.element.isDirectory) {
				this.openFile(e.element.resource);
			}
		}));
		this._register(this.configurationService.onDidChangeConfiguration(e => {
			if (e.affectsConfiguration('files.exclude')) {
				this.updateExcludes();
				this.scheduleRefresh();
			}
		}));
		this._register(this.terminalService.onDidChangeActiveInstance(() => this.trackActiveInstance()));
		this._register(this.mapo.onDidChange(() => this.trackActiveInstance()));
		this.trackActiveInstance();
	}

	protected override layoutBody(height: number, width: number): void {
		super.layoutBody(height, width);
		const messageHeight = this.message && !this.message.classList.contains('hidden') ? this.message.offsetHeight : 0;
		this.tree?.layout(height - messageHeight, width);
	}

	private updateExcludes(): void {
		const expression = this.configurationService.getValue<glob.IExpression>('files.exclude');
		this.excludeMatcher = glob.parse(expression ?? {});
	}

	private isExcluded(node: IFileNode): boolean {
		if (!this.root) {
			return false;
		}
		const relative = relativePath(this.root, node.resource) ?? node.name;
		return !!this.excludeMatcher(relative, node.name);
	}

	private trackActiveInstance(): void {
		const instance = this.terminalService.activeInstance;
		if (instance !== this.trackedInstance) {
			this.trackedInstance = instance;
			this.instanceListeners.clear();
			if (instance) {
				const cwdDetection = instance.capabilities.get(TerminalCapability.CwdDetection);
				if (cwdDetection) {
					this.instanceListeners.add(cwdDetection.onDidChangeCwd(() => this.updateRootFromInstance()));
				}
				this.instanceListeners.add(instance.capabilities.onDidAddCapability(e => {
					if (e.id === TerminalCapability.CwdDetection) {
						this.instanceListeners.add(e.capability.onDidChangeCwd(() => this.updateRootFromInstance()));
						this.updateRootFromInstance();
					}
				}));
			}
		}
		this.updateRootFromInstance();
	}

	private updateRootFromInstance(): void {
		const instance = this.trackedInstance;
		let path: string | undefined;
		if (instance) {
			path = instance.capabilities.get(TerminalCapability.CwdDetection)?.getCwd() || this.mapo.getTabForInstance(instance)?.tab.cwd;
		}
		this.setRoot(path ? URI.file(path) : undefined).catch(err => this.logService?.error?.(err));
	}

	private async setRoot(root: URI | undefined): Promise<void> {
		if (root && this.root && isEqual(root, this.root)) {
			return;
		}
		this.root = root;
		this.rootListeners.clear();
		if (!root) {
			this.updateTitle(localize('mapo.explorer', "Explorer"));
			this.showMessage(localize('mapo.explorer.noTerminal', "Open a terminal tab to browse its folder."));
			return;
		}
		this.updateTitle(basename(root));
		if (!(await this.fileService.exists(root))) {
			this.showMessage(localize('mapo.explorer.missing', "Folder not found: {0}", this.labelService.getUriLabel(root)));
			return;
		}
		this.hideMessage();
		this.rootListeners.add(this.fileService.watch(root, { recursive: true, excludes: ['**/node_modules/**', '**/.git/**'] }));
		this.rootListeners.add(this.fileService.onDidFilesChange(e => {
			if (e.affects(root)) {
				this.scheduleRefresh();
			}
		}));
		await this.tree?.setInput({ resource: root, name: basename(root), isDirectory: true });
	}

	private scheduleRefresh(): void {
		this.refreshDelayer.trigger(() => this.tree?.updateChildren() ?? Promise.resolve()).catch(() => { /* view disposed or refresh superseded */ });
	}

	private showMessage(text: string): void {
		if (this.message) {
			this.message.textContent = text;
			this.message.classList.remove('hidden');
		}
		this.treeContainer?.classList.add('hidden');
	}

	private hideMessage(): void {
		this.message?.classList.add('hidden');
		this.treeContainer?.classList.remove('hidden');
	}

	private openFile(resource: URI): void {
		const group = this.editorService.activeEditor instanceof TerminalEditorInput ? SIDE_GROUP : ACTIVE_GROUP;
		this.editorService.openEditor({ resource, options: { pinned: false } }, group);
	}
}
```

Notes for the implementer:
- `ViewPane` does not expose `logService`; replace the `.catch(err => this.logService?.error?.(err))` in `updateRootFromInstance` with `.catch(onUnexpectedError)` from `base/common/errors.js`.
- Add `.mapo-explorer .mapo-explorer-tree.hidden { display: none; }` to `mapo.css`.
- `glob.parse` returns a function `(path, basename?) => string | null | Promise<...>`; the `!!` cast in `isExcluded` treats a pending promise as excluded, which only happens for sibling-clause patterns (`when`). Acceptable for v1.

- [ ] **Step 2: Register the view**

In `mapo.contribution.ts` add the import `import { MapoExplorerView } from './mapoExplorerView.js';` and `MAPO_EXPLORER_VIEW_ID` to the `mapoViews.js` import, then after `mapoExplorerContainer` is defined:

```ts
viewsRegistry.registerViews([{
	id: MAPO_EXPLORER_VIEW_ID,
	name: localize2('mapo.explorer', "Explorer"),
	containerIcon: Codicon.files,
	ctorDescriptor: new SyncDescriptor(MapoExplorerView),
	canToggleVisibility: false,
	canMoveView: false,
	order: 0,
}], mapoExplorerContainer);
```

Remove the `export` from `mapoExplorerContainer` if nothing else imports it.

- [ ] **Step 3: Type-check, lint, launch**

`tail -3 .../watch-client.log` shows 0 errors; `npx eslint src/vs/workbench/contrib/mapo` clean.
Launch `./scripts/mapo.sh --user-data-dir=/tmp/mapo-dev-profile`. Create a workspace, add a terminal tab in `~/code/mapo`. Expected: the right side bar title becomes `mapo` and lists the repo files with icons. Run `cd src` in the terminal: the tree re-roots to `src` within a second (shell integration must be on, which is the default). Click a file: it opens in a group to the right of the terminal. Click a second file: it opens in that same right group. Modify a tracked file in the editor: the gutter shows a git change marker.

- [ ] **Step 4: Commit**

```bash
git add src/vs/workbench/contrib/mapo
git commit -m "mapo: add cwd-following explorer view

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Product rename

**Files:**
- Modify: `product.json` (`nameShort`, `nameLong`)

- [ ] **Step 1: Rename**

Change `"nameShort": "Code - OSS"` to `"nameShort": "Mapo"` and `"nameLong": "Code - OSS"` to `"nameLong": "Mapo"`. Leave `applicationName`, `dataFolderName`, `darwinBundleIdentifier` and `urlProtocol` unchanged.

- [ ] **Step 2: Rebuild the Electron bundle**

Run: `npm run electron`
Expected: `.build/electron/Mapo.app` exists. `./scripts/mapo.sh` launches and the window title / menu bar say "Mapo".

- [ ] **Step 3: Confirm tests still run**

Run: `./scripts/test.sh --run src/vs/workbench/contrib/mapo/test/common/mapoWorkspace.test.ts`
Expected: passing (this proves `scripts/test.sh` found the renamed binary).

- [ ] **Step 4: Commit**

```bash
git add product.json
git commit -m "mapo: rename product to Mapo

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Manual acceptance pass

**Files:** none new; fix whatever the pass uncovers in `src/vs/workbench/contrib/mapo/`.

- [ ] **Step 1: Run all Mapo unit tests**

Run: `./scripts/test.sh --runGlob '**/contrib/mapo/**/*.test.js'`
Expected: all passing.

- [ ] **Step 2: Walk the spec's six acceptance steps**

Launch `./scripts/mapo.sh --user-data-dir=/tmp/mapo-acceptance` and verify each item; take a screenshot for each state if a screenshot tool is available:

1. App opens with Workspaces on the left, empty tab area, Explorer on the right, no activity bar, no status bar, no panel.
2. Create workspace "A", add a Claude tab in `~/code/mapo`. The explorer shows that folder. The tab title follows the process (shows the Claude Code title once it starts). The left row shows "Claude is running" while Claude works and "Claude is waiting for your input" after it rings the bell.
3. Add a terminal tab, `cd` somewhere. The explorer follows.
4. Click a file. It opens split to the right of the terminal. Git gutter decorations appear after editing a tracked file.
5. Create workspace "B" with its own tab. Switch A/B by clicking rows and with Cmd+Ctrl+Down/Up. Terminal contents survive the switch (scrollback still there).
6. Quit and relaunch. Both workspaces and their tabs come back, terminals relaunched in their folders, and the previously active workspace is active.

- [ ] **Step 3: Fix and re-verify**

For every failure: write a failing unit test when the defect is in the service/data source/branch reader, fix, re-run that test file, and re-check the manual step. Commit each fix separately:

```bash
git add src/vs/workbench/contrib/mapo
git commit -m "mapo: <what was fixed>

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 4: Report**

Summarize what passed, what was fixed, and anything left open (for example: Claude "waiting" detection depends on the bell, which Claude Code emits only when its notification channel is the terminal bell).
