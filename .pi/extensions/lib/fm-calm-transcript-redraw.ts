// Pi 0.83.0's InteractiveMode.setToolsExpanded is the only supported seam that
// re-invokes every already-mounted row's renderers, which is how a Calm change
// reaches rows that were rendered before it. It ends in showStatus, and
// showStatus appends a permanent Spacer + Text pair to chatContainer rather
// than drawing a transient footer, so using it verbatim would leave a stray
// "Tool output: ..." row in the very transcript Calm exists to keep quiet.
// This adapter probes that exact pair and suppresses only the status append for
// the duration of a Calm redraw, keeping showStatus's render request so the
// re-invoked rows still repaint. It degrades independently: without it,
// redrawCalmTranscript still redraws through the stock call.
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";

type CalmRedrawTarget = {
  getToolsExpanded(): boolean;
  setToolsExpanded(expanded: boolean): void;
};

type InteractiveModePresentation = {
  setToolsExpanded(expanded: boolean): void;
  showStatus(message: string): void;
  ui?: { requestRender?(): void };
};

type CalmTranscriptRedrawPatch = {
  depth: number;
};

const CALM_TRANSCRIPT_REDRAW_PATCH = Symbol.for(
  "firstmate:calm-transcript-redraw:pi-0.83.0",
);

type CalmRedrawRegistry = typeof globalThis & {
  [key: symbol]: CalmTranscriptRedrawPatch | undefined;
};

export function installCalmTranscriptRedraw(): void {
  const registry = globalThis as CalmRedrawRegistry;
  if (registry[CALM_TRANSCRIPT_REDRAW_PATCH]) return;

  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as InteractiveModePresentation;
  const originalSetToolsExpanded = prototype.setToolsExpanded;
  if (typeof originalSetToolsExpanded !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.setToolsExpanded");
  }
  if (typeof prototype.showStatus !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.showStatus");
  }

  const patch: CalmTranscriptRedrawPatch = { depth: 0 };
  prototype.setToolsExpanded = function (expanded: boolean): void {
    if (patch.depth === 0) {
      originalSetToolsExpanded.call(this, expanded);
      return;
    }
    const instance = this as InteractiveModePresentation;
    const ownStatus = Object.getOwnPropertyDescriptor(instance, "showStatus");
    instance.showStatus = function (this: InteractiveModePresentation): void {
      this.ui?.requestRender?.();
    };
    try {
      originalSetToolsExpanded.call(this, expanded);
    } finally {
      if (ownStatus) Object.defineProperty(instance, "showStatus", ownStatus);
      else delete (instance as Partial<InteractiveModePresentation>).showStatus;
    }
  };

  registry[CALM_TRANSCRIPT_REDRAW_PATCH] = patch;
}

// Re-invoke every mounted row's renderers under the caller's current expansion
// choice. Passing the current value keeps Ctrl+O state untouched by definition,
// unlike a toggle-and-restore pair that briefly flips every row.
export function redrawCalmTranscript(ui: CalmRedrawTarget): void {
  const patch = (globalThis as CalmRedrawRegistry)[CALM_TRANSCRIPT_REDRAW_PATCH];
  if (patch) patch.depth += 1;
  try {
    ui.setToolsExpanded(ui.getToolsExpanded());
  } finally {
    if (patch) patch.depth -= 1;
  }
}
