// Pi exports AssistantMessageComponent with an updateContent method.
// installCalmAssistantLayout() probes that exact method and throws if it is missing;
// fm-calm.ts catches that and skips only this adapter with a diagnostic instead of
// blocking Calm or Pi.
// The adapter owns both collapsed-thinking layout and the presentation-only exact
// operational acknowledgement rule.
// Acknowledgement origin is scoped to one agent run rather than to the most recent user
// row: a run counts as operational only while every Firstmate input it carries is
// canonically operational, so a wake steered into a still-running captain turn keeps that
// run's replies visible.
// Pi opens a run with agent_start before the run's initiating user message_start, drains
// steered and queued inputs into that same run, and settles it from a finally block. The
// accumulator records the first input of a run whichever order those two arrive in, so a
// future Pi that emits them the other way round still accumulates instead of overwriting.
// Pi also rebuilds the whole transcript through InteractiveMode.renderSessionItems,
// including the rebuild it performs when it auto-compacts inside a run. Rows replayed in
// that window are scored per row against their own preceding input and never disturb the
// run scope. Every unresolved case resolves to visible.
import type { AssistantMessageComponent as PiAssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import { calmPresentationHides } from "./fm-calm-visibility.ts";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];

type AssistantMessagePresentationState = {
  hiddenThinkingLabel: string;
  hideThinkingBlock: boolean;
  lastMessage?: AssistantMessage;
};

type CalmAssistantLayoutPatch = {
  assistantOperationalOrigins: WeakMap<object, boolean>;
  replayDepth: number;
  replayOriginIsOperational: boolean;
  runIsActive: boolean;
  runOriginIsOperational: boolean;
  runOriginRecorded: boolean;
  hidesOperationalAcknowledgement: () => boolean;
  hidesThinking: () => boolean;
};

// The symbol changes only when the patch shape changes, so a compatible upgrade cannot
// double-patch a live process and an incompatible one cannot keep a stale closure
// installed under the same key.
const CALM_ASSISTANT_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-assistant-layout:operational-ack-v1",
);
const FIRSTMATE_NO_ACTION_ACKNOWLEDGEMENT = "Captain, shipshape.";

function registry(): typeof globalThis & {
  [key: symbol]: CalmAssistantLayoutPatch | undefined;
} {
  return globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
}

export function noteCalmTranscriptUserMessage(isOperational: boolean): void {
  const patch = registry()[CALM_ASSISTANT_LAYOUT_PATCH];
  if (!patch) return;
  if (patch.replayDepth > 0) {
    patch.replayOriginIsOperational = isOperational;
    return;
  }
  if (patch.runIsActive && patch.runOriginRecorded) {
    patch.runOriginIsOperational = patch.runOriginIsOperational && isOperational;
    return;
  }
  patch.runOriginIsOperational = isOperational;
  patch.runOriginRecorded = true;
}

export function beginCalmTranscriptReplay(): void {
  const patch = registry()[CALM_ASSISTANT_LAYOUT_PATCH];
  if (!patch) return;
  if (patch.replayDepth === 0) patch.replayOriginIsOperational = false;
  patch.replayDepth += 1;
}

export function endCalmTranscriptReplay(): void {
  const patch = registry()[CALM_ASSISTANT_LAYOUT_PATCH];
  if (!patch || patch.replayDepth === 0) return;
  patch.replayDepth -= 1;
}

export function noteCalmTranscriptRunStart(): void {
  const patch = registry()[CALM_ASSISTANT_LAYOUT_PATCH];
  if (patch) patch.runIsActive = true;
}

export function noteCalmTranscriptRunSettled(): void {
  const patch = registry()[CALM_ASSISTANT_LAYOUT_PATCH];
  if (!patch) return;
  patch.runIsActive = false;
  patch.runOriginRecorded = false;
}

export function resetCalmTranscriptOrigin(): void {
  const patch = registry()[CALM_ASSISTANT_LAYOUT_PATCH];
  if (!patch) return;
  patch.replayDepth = 0;
  patch.replayOriginIsOperational = false;
  patch.runIsActive = false;
  patch.runOriginIsOperational = false;
  patch.runOriginRecorded = false;
}

function withoutOperationalAcknowledgement(
  message: AssistantMessage,
  isOperational: boolean,
  hidesAcknowledgement: boolean,
): AssistantMessage {
  if (!isOperational || !hidesAcknowledgement) return message;
  if (message.content.some((block) => block.type === "toolCall")) return message;

  const text = message.content
    .map((block) => (block.type === "text" ? block.text : ""))
    .join("");
  const isStreamingPrefix =
    message.stopReason === "pending" &&
    FIRSTMATE_NO_ACTION_ACKNOWLEDGEMENT.startsWith(text);
  const isFinalAcknowledgement =
    message.stopReason === "stop" &&
    text === FIRSTMATE_NO_ACTION_ACKNOWLEDGEMENT;
  if (!isStreamingPrefix && !isFinalAcknowledgement) return message;

  return {
    ...message,
    content: message.content.filter((block) => block.type !== "text"),
  };
}

export function installCalmAssistantLayout(): void {
  const hidesThinking = (): boolean => calmPresentationHides("assistant-thinking");
  const hidesOperationalAcknowledgement = (): boolean =>
    calmPresentationHides("synthetic-assistant");
  const installed = registry()[CALM_ASSISTANT_LAYOUT_PATCH];
  if (installed) {
    installed.hidesThinking = hidesThinking;
    installed.hidesOperationalAcknowledgement = hidesOperationalAcknowledgement;
    return;
  }

  const patch: CalmAssistantLayoutPatch = {
    assistantOperationalOrigins: new WeakMap<object, boolean>(),
    replayDepth: 0,
    replayOriginIsOperational: false,
    runIsActive: false,
    runOriginIsOperational: false,
    runOriginRecorded: false,
    hidesOperationalAcknowledgement,
    hidesThinking,
  };
  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent");
  }
  const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.updateContent");
  }

  AssistantMessageComponent.prototype.updateContent = function (
    message: AssistantMessage,
  ): void {
    const state = this as unknown as AssistantMessagePresentationState;
    let isOperational = patch.assistantOperationalOrigins.get(this);
    if (isOperational === undefined) {
      isOperational =
        patch.replayDepth > 0
          ? patch.replayOriginIsOperational
          : patch.runOriginIsOperational;
      patch.assistantOperationalOrigins.set(this, isOperational);
    }
    const hideThinking =
      state.hiddenThinkingLabel === "" &&
      state.hideThinkingBlock &&
      patch.hidesThinking();
    const acknowledgementPresentation = withoutOperationalAcknowledgement(
      message,
      isOperational,
      patch.hidesOperationalAcknowledgement(),
    );
    const presentationMessage = hideThinking
      ? {
          ...acknowledgementPresentation,
          content: acknowledgementPresentation.content.filter(
            (block) => block.type !== "thinking",
          ),
        }
      : acknowledgementPresentation;

    originalUpdateContent.call(this, presentationMessage);
    if (presentationMessage !== message) state.lastMessage = message;
  };

  registry()[CALM_ASSISTANT_LAYOUT_PATCH] = patch;
}
