// Firstmate's home-persistent Pi transcript presentation toggle.
//
// Verified against Pi 0.81.1, 0.82.0, and 0.84.1, which expose built-in ToolDefinitions, per-slot
// renderers, renderShell: "self", session_start replacement reasons, agent_start and
// agent_settled, ExtensionUIContext.setToolsExpanded(), setWorkingVisible(), setWidget()
// with a disposable component factory, and setHiddenThinkingLabel().
// ./lib/fm-calm-working-ship.ts owns the animated working presentation this file
// installs. The focused tests pin those assumptions but never reject a
// newer Pi solely for its version. The collapsed-thinking, built-in-tool-row,
// operational-user, transcript-replay, and transcript-redraw presentation adapters
// probe the exact API they patch and degrade independently with a diagnostic naming
// the adapter and the running Pi version
// (see installCalmPresentationAdapter below) if a future Pi removes it; Pi
// still exposes no global renderer for arbitrary built-in or custom rows.
// docs/configuration.md owns the home-local Calm preference contract.
//
// Pi has one complete ToolDefinition slot per tool name and rejects duplicate extension
// registrations during initial load. Keep extension-load registration empty and claim
// only uncontested built-ins from session_start or first activation, when getAllTools()
// is reliable. The exported component adapter above keeps already-mounted and replayed
// rows controllable without taking their execution definition. docs/calm-mode-feasibility.md
// owns the Pi-source evidence.
import { randomUUID } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ExtensionAPI,
  ExtensionContext,
  ExtensionUIContext,
  ToolDefinition,
  ToolInfo,
  ToolRenderResultOptions,
} from "@earendil-works/pi-coding-agent";
import {
  createBashToolDefinition,
  createEditToolDefinition,
  createFindToolDefinition,
  createGrepToolDefinition,
  createLsToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
  ToolExecutionComponent,
  VERSION as PI_VERSION,
} from "@earendil-works/pi-coding-agent";
import {
  Box,
  Container,
  getKeybindings,
  type Component,
  type TUI,
} from "@earendil-works/pi-tui";
import type { TSchema } from "typebox";
import {
  installCalmAssistantLayout,
  noteCalmTranscriptRunSettled,
  noteCalmTranscriptRunStart,
  resetCalmTranscriptOrigin,
} from "./lib/fm-calm-assistant-layout.ts";
import {
  installCalmOperationalUserLayout,
  installCalmTranscriptReplayWindow,
} from "./lib/fm-calm-operational-user-layout.ts";
import {
  CALM_WORKING_SHIP_WIDGET_KEY,
  createCalmWorkingShipAnimation,
  createCalmWorkingShipWidget,
} from "./lib/fm-calm-working-ship.ts";
import {
  calmPresentationHides,
  calmPresentationIsActive,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
  registerFirstmateSyntheticPresentation,
  setCalmPresentation,
  setCalmStockExportRendering,
} from "./lib/fm-calm-visibility.ts";

type DefinitionFactory<TParams extends TSchema, TDetails, TState> = (
  cwd: string,
) => ToolDefinition<TParams, TDetails, TState>;

type RenderContext<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderCall"]>
>[2];

type RenderArgs<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderCall"]>
>[0];

type RenderTheme<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderCall"]>
>[1];

type RenderResult<TParams extends TSchema, TDetails, TState> = Parameters<
  NonNullable<ToolDefinition<TParams, TDetails, TState>["renderResult"]>
>[0];

type StandardShellState = {
  shell?: Box;
  call?: Component;
  result?: Component;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const CALM_REDRAW_CAPTURE_WIDGET_KEY = "firstmate-calm-redraw-capture";

const realpathOrSelf = (path: string): string => {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
};
const extensionRealFile = realpathOrSelf(extensionFile);
const CALM_BUILT_IN_TOOL_NAMES = new Set([
  "read",
  "bash",
  "edit",
  "write",
  "grep",
  "find",
  "ls",
]);

type ToolExecutionPresentation = {
  imageComponents?: Component[];
  imageSpacers?: Array<Component | undefined>;
  toolName?: string;
};
type CalmBuiltInToolLayoutPatch = {
  hidesBuiltInRows: () => boolean;
};
const CALM_BUILT_IN_TOOL_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-built-in-tool-layout:pi-0.84.1",
);

// Tool rows created before Calm first claims an uncontested built-in keep the
// ToolDefinition captured by Pi's constructor. Patch Pi's exported component render
// seam so those mounted rows still follow Calm, while leaving their execution owner
// untouched. Image children remain visible, matching the established wrapper boundary.
function installCalmBuiltInToolLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmBuiltInToolLayoutPatch | undefined;
  };
  const hidesBuiltInRows = (): boolean =>
    calmPresentationHides("assistant-tool-call") &&
    calmPresentationHides("tool-result");
  const installed = registry[CALM_BUILT_IN_TOOL_LAYOUT_PATCH];
  if (installed) {
    installed.hidesBuiltInRows = hidesBuiltInRows;
    return;
  }
  if (typeof ToolExecutionComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent");
  }
  const originalRender = ToolExecutionComponent.prototype.render;
  if (typeof originalRender !== "function") {
    throw new Error("Firstmate Calm requires Pi ToolExecutionComponent.render");
  }
  const patch: CalmBuiltInToolLayoutPatch = { hidesBuiltInRows };
  ToolExecutionComponent.prototype.render = function (width: number): string[] {
    const state = this as unknown as ToolExecutionPresentation;
    if (
      !patch.hidesBuiltInRows() ||
      typeof state.toolName !== "string" ||
      !CALM_BUILT_IN_TOOL_NAMES.has(state.toolName)
    ) {
      return originalRender.call(this, width);
    }

    const images = state.imageComponents ?? [];
    const spacers = state.imageSpacers ?? [];
    const lines: string[] = [];
    for (let index = 0; index < images.length; index += 1) {
      const spacer = spacers[index];
      if (spacer) lines.push(...spacer.render(width));
      lines.push(...images[index].render(width));
    }
    return lines;
  };
  registry[CALM_BUILT_IN_TOOL_LAYOUT_PATCH] = patch;
}

// Each presentation adapter probes the exact Pi API it patches. If a future Pi removes
// that API, only the affected adapter degrades; the rest of Calm keeps working.
function installCalmPresentationAdapter(name: string, install: () => void): void {
  try {
    install();
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`Firstmate Calm: ${name} presentation adapter unavailable, skipping. ${reason}`);
  }
}

export default function (pi: ExtensionAPI) {
  installCalmPresentationAdapter("collapsed-thinking", installCalmAssistantLayout);
  installCalmPresentationAdapter("built-in-tool-row", installCalmBuiltInToolLayout);
  installCalmPresentationAdapter("operational-user-row", installCalmOperationalUserLayout);
  installCalmPresentationAdapter("transcript-replay-window", installCalmTranscriptReplayWindow);

  let exportRendering = false;
  let removeTerminalInputHandler: (() => void) | undefined;
  let presentationTui: TUI | undefined;
  // One logical agent run, tracked from agent_start through agent_settled rather than
  // from turns or tool calls, so the boat never flickers between tool calls, automatic
  // continuations, retries, or compaction that stay inside the same run.
  let agentRunActive = false;
  let workingShipShown = false;
  // One animation instance per extension lifetime. Hiding the working widget freezes
  // this state; the next working period resumes it. session_start resets it so a fresh
  // Pi session starts at the normal initial position. Never module-global.
  const workingShipAnimation = createCalmWorkingShipAnimation();

  // Single owner of Calm's working-row presentation choice. The widget is only created
  // or removed on a real transition, so repeated starts cannot duplicate its timer.
  const applyWorkingPresentation = (
    ui: ExtensionUIContext,
    forceStockVisibility = false,
  ): void => {
    const showShip = agentRunActive && calmPresentationIsActive();
    if (showShip !== workingShipShown) {
      workingShipShown = showShip;
      ui.setWidget(
        CALM_WORKING_SHIP_WIDGET_KEY,
        showShip
          ? (tui) => createCalmWorkingShipWidget(tui, workingShipAnimation)
          : undefined,
      );
      ui.setWorkingVisible(!showShip);
    } else if (forceStockVisibility && !showShip) {
      ui.setWorkingVisible(true);
    }
  };

  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configDirectory = process.env.FM_CONFIG_OVERRIDE || resolve(fmHome, "config");
  const calmPreferencePath = resolve(configDirectory, "calm");
  const loadCalmPreference = (): boolean => {
    try {
      return readFileSync(calmPreferencePath, "utf8").trim() === "on";
    } catch {
      return false;
    }
  };
  const persistCalmPreference = (active: boolean): void => {
    mkdirSync(dirname(calmPreferencePath), { recursive: true });
    const temporaryPath = `${calmPreferencePath}.${process.pid}.${randomUUID()}.tmp`;
    try {
      writeFileSync(temporaryPath, active ? "on\n" : "off\n", {
        encoding: "utf8",
        flag: "wx",
        mode: 0o600,
      });
      renameSync(temporaryPath, calmPreferencePath);
    } finally {
      rmSync(temporaryPath, { force: true });
    }
  };

  const publishPresentationState = (): void => {
    pi.events.emit(FIRSTMATE_CALM_PRESENTATION_EVENT, {
      active: calmPresentationIsActive(),
      stockExportRendering: exportRendering,
    });
  };

  // Pi 0.84's regular TUI can retain already-painted rows when a renderer shrinks to
  // zero height until a later unrelated frame. The documented widget factory is the
  // extension surface that supplies the current TUI, whose forced request discards the
  // stale frame. Capture it without keeping a widget or changing transcript geometry.
  // Outside "tui" mode Pi supplies a no-op setWidget by design, so only a TUI session
  // that fails to yield a usable TUI is drift, and that drift is reported through the
  // same adapter diagnostic as every other Calm seam.
  const capturePresentationTui = (ctx: ExtensionContext): void => {
    presentationTui = undefined;
    installCalmPresentationAdapter("transcript-redraw", () => {
      let captured: TUI | undefined;
      ctx.ui.setWidget(CALM_REDRAW_CAPTURE_WIDGET_KEY, (tui) => {
        captured = tui;
        return new Container();
      });
      ctx.ui.setWidget(CALM_REDRAW_CAPTURE_WIDGET_KEY, undefined);
      if (captured && typeof captured.requestRender === "function") {
        presentationTui = captured;
        return;
      }
      if (ctx.mode !== "tui") return;
      throw new Error(
        captured
          ? `Pi ${PI_VERSION} no longer exposes TUI.requestRender(), so Calm cannot force a transcript redraw.`
          : `Pi ${PI_VERSION} did not invoke the setWidget() component factory while capturing the TUI, so Calm cannot force a transcript redraw.`,
      );
    });
  };
  const forcePresentationRedraw = (): void => {
    presentationTui?.requestRender(true);
  };
  const rebuildTranscriptRows = (ui: ExtensionUIContext): void => {
    const expanded = ui.getToolsExpanded();
    ui.setToolsExpanded(!expanded);
    ui.setToolsExpanded(expanded);
    forcePresentationRedraw();
  };

  registerFirstmateSyntheticPresentation(pi);

  function wrapBuiltIn<TParams extends TSchema, TDetails, TState>(
    factory: DefinitionFactory<TParams, TDetails, TState>,
  ): ToolDefinition<TParams, TDetails, TState> {
    const definitions = new Map<string, ToolDefinition<TParams, TDetails, TState>>();
    const definitionFor = (cwd: string): ToolDefinition<TParams, TDetails, TState> => {
      let definition = definitions.get(cwd);
      if (!definition) {
        definition = factory(cwd);
        definitions.set(cwd, definition);
      }
      return definition;
    };

    const original = definitionFor(process.cwd());
    const originalRenderCall = original.renderCall;
    const originalRenderResult = original.renderResult;
    const originalSelfShell = original.renderShell === "self";
    const standardShells = new WeakMap<object, StandardShellState>();

    if (!originalRenderCall || !originalRenderResult) {
      throw new Error(`Firstmate calm mode requires both render slots for Pi built-in tool ${original.name}`);
    }

    const shellStateFor = (
      context: RenderContext<TParams, TDetails, TState>,
    ): StandardShellState => {
      const rowState = context.state as object;
      let shellState = standardShells.get(rowState);
      if (!shellState) {
        shellState = {};
        standardShells.set(rowState, shellState);
      }
      return shellState;
    };

    const refreshStandardShell = (
      state: StandardShellState,
      theme: RenderTheme<TParams, TDetails, TState>,
      context: RenderContext<TParams, TDetails, TState>,
    ): Box => {
      const background = context.isPartial
        ? (text: string) => theme.bg("toolPendingBg", text)
        : context.isError
          ? (text: string) => theme.bg("toolErrorBg", text)
          : (text: string) => theme.bg("toolSuccessBg", text);
      const shell = state.shell ?? new Box(1, 1, background);
      state.shell = shell;
      shell.setBgFn(background);
      shell.clear();
      if (state.call) shell.addChild(state.call);
      if (state.result) shell.addChild(state.result);
      return shell;
    };

    return {
      ...original,
      renderShell: "self",

      async execute(toolCallId, params, signal, onUpdate, ctx) {
        return definitionFor(ctx.cwd).execute(toolCallId, params, signal, onUpdate, ctx);
      },

      renderCall(
        args: RenderArgs<TParams, TDetails, TState>,
        theme: RenderTheme<TParams, TDetails, TState>,
        context: RenderContext<TParams, TDetails, TState>,
      ) {
        if (exportRendering) return originalRenderCall(args, theme, context);
        if (calmPresentationHides("assistant-tool-call")) return new Container();
        if (originalSelfShell) return originalRenderCall(args, theme, context);

        const state = shellStateFor(context);
        state.call = originalRenderCall(args, theme, {
          ...context,
          lastComponent: state.call,
        });
        return refreshStandardShell(state, theme, context);
      },

      renderResult(
        result: RenderResult<TParams, TDetails, TState>,
        options: ToolRenderResultOptions,
        theme: RenderTheme<TParams, TDetails, TState>,
        context: RenderContext<TParams, TDetails, TState>,
      ) {
        if (exportRendering) return originalRenderResult(result, options, theme, context);
        if (calmPresentationHides("tool-result")) return new Container();
        if (originalSelfShell) return originalRenderResult(result, options, theme, context);

        const state = shellStateFor(context);
        state.result = originalRenderResult(result, options, theme, {
          ...context,
          lastComponent: state.result,
        });
        refreshStandardShell(state, theme, context);
        return new Container();
      },
    };
  }

  const wrappedBuiltIns: ToolDefinition<any, any, any>[] = [
    wrapBuiltIn(createReadToolDefinition),
    wrapBuiltIn(createBashToolDefinition),
    wrapBuiltIn(createEditToolDefinition),
    wrapBuiltIn(createWriteToolDefinition),
    wrapBuiltIn(createGrepToolDefinition),
    wrapBuiltIn(createFindToolDefinition),
    wrapBuiltIn(createLsToolDefinition),
  ];
  let builtInsRegistered = false;

  function registeredTools(): ToolInfo[] | undefined {
    try {
      return pi.getAllTools();
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      console.error(`Firstmate Calm: built-in ownership check unavailable. ${reason}`);
      return undefined;
    }
  }

  function ownerIsForeign(owner: ToolInfo["sourceInfo"] | undefined): boolean {
    return (
      owner !== undefined &&
      owner.source !== "builtin" &&
      realpathOrSelf(owner.path) !== extensionRealFile
    );
  }

  function activateBuiltInsIfNeeded(ui: ExtensionUIContext): void {
    if (builtInsRegistered) return;
    const registered = registeredTools();
    if (registered === undefined) {
      builtInsRegistered = true;
      ui.notify(
        "Firstmate Calm: built-in ownership could not be checked, so Calm left every built-in tool definition unchanged this session.",
        "warning",
      );
      return;
    }
    const contested = wrappedBuiltIns.filter((tool) => {
      const owner = registered.find((info) => info.name === tool.name)?.sourceInfo;
      return ownerIsForeign(owner);
    });
    const contestedNames = new Set(contested.map((tool) => tool.name));
    for (const tool of wrappedBuiltIns) {
      if (!contestedNames.has(tool.name)) pi.registerTool(tool);
    }
    builtInsRegistered = true;
    if (contested.length === 0) return;

    const names = contested.map((tool) => `"${tool.name}"`).join(", ");
    const plural = contested.length > 1;
    ui.notify(
      `Firstmate Calm: the ${names} built-in tool${plural ? "s are" : " is"} already provided by another extension, so Calm may not fully function for ${plural ? "them" : "it"} this session.`,
      "warning",
    );
    for (const tool of contested) {
      console.error(`Firstmate Calm: skipped claiming built-in "${tool.name}" because another extension already owns it.`);
    }
  }

  // Report any later-observable loss rather than silently claiming that Calm controls
  // a tool definition owned elsewhere.
  function reportBuiltInLosses(): void {
    if (!builtInsRegistered) return;
    const registered = registeredTools();
    if (!registered) return;
    for (const tool of wrappedBuiltIns) {
      const owner = registered.find((info) => info.name === tool.name)?.sourceInfo;
      if (!ownerIsForeign(owner)) continue;
      console.error(
        `Firstmate Calm: another extension (${owner.path}) owns the built-in "${tool.name}" tool; Calm's presentation for it is unavailable this session.`,
      );
    }
  }

  pi.on("session_start", (_event, ctx) => {
    resetCalmTranscriptOrigin();
    exportRendering = false;
    setCalmPresentation(loadCalmPreference());
    if (calmPresentationIsActive()) activateBuiltInsIfNeeded(ctx.ui);
    reportBuiltInLosses();
    setCalmStockExportRendering(false);
    publishPresentationState();
    agentRunActive = false;
    workingShipShown = false;
    // A genuine new session lifetime starts the boat at the normal initial position.
    workingShipAnimation.reset();
    capturePresentationTui(ctx);
    applyWorkingPresentation(ctx.ui, true);
    ctx.ui.setHiddenThinkingLabel(calmPresentationIsActive() ? "" : undefined);
    ctx.ui.setStatus("firstmate-calm", undefined);
    removeTerminalInputHandler?.();
    removeTerminalInputHandler = ctx.ui.onTerminalInput((data) => {
      if (!getKeybindings().matches(data, "tui.input.submit")) return;

      const input = ctx.ui.getEditorText().trim();
      if (
        input !== "/share" &&
        input !== "/export" &&
        !input.startsWith("/export ")
      ) {
        return;
      }

      exportRendering = true;
      setCalmStockExportRendering(true);
      publishPresentationState();
      setTimeout(() => {
        exportRendering = false;
        setCalmStockExportRendering(false);
        publishPresentationState();
        rebuildTranscriptRows(ctx.ui);
      }, 0);
    });
  });

  pi.on("agent_start", (_event, ctx) => {
    noteCalmTranscriptRunStart();
    agentRunActive = true;
    applyWorkingPresentation(ctx.ui);
  });

  // agent_settled is emitted from a finally block, so it also covers abort and failure.
  pi.on("agent_settled", (_event, ctx) => {
    noteCalmTranscriptRunSettled();
    agentRunActive = false;
    applyWorkingPresentation(ctx.ui);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    noteCalmTranscriptRunSettled();
    agentRunActive = false;
    applyWorkingPresentation(ctx.ui);
  });

  pi.registerCommand("calm", {
    description: "Toggle Firstmate's supported conversation-only transcript presentation.",
    handler: async (_args, ctx) => {
      const active = !calmPresentationIsActive();
      persistCalmPreference(active);
      setCalmPresentation(active);
      if (active) activateBuiltInsIfNeeded(ctx.ui);
      publishPresentationState();
      applyWorkingPresentation(ctx.ui, true);
      ctx.ui.setHiddenThinkingLabel(active ? "" : undefined);
      ctx.ui.setStatus("firstmate-calm", undefined);

      rebuildTranscriptRows(ctx.ui);
    },
  });
}
