// Pi exports AssistantMessageComponent with an updateContent method.
// installCalmAssistantLayout() probes that exact method and throws if it is missing;
// fm-calm.ts catches that and skips only this adapter with a diagnostic instead of
// blocking Calm or Pi.
// The adapter owns both collapsed-thinking layout and the presentation-only exact
// operational acknowledgement rule.
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
  currentInputIsOperational: boolean;
  hidesOperationalAcknowledgement: () => boolean;
  hidesThinking: () => boolean;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
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
  if (patch) patch.currentInputIsOperational = isOperational;
}

export function resetCalmTranscriptOrigin(): void {
  const patch = registry()[CALM_ASSISTANT_LAYOUT_PATCH];
  if (patch) patch.currentInputIsOperational = false;
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
    currentInputIsOperational: false,
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
      isOperational = patch.currentInputIsOperational;
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
