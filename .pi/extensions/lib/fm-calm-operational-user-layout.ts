// Pi adds the ordinary-user spacer and row together through
// InteractiveMode.addMessageToChat, and replays or rebuilds the whole transcript through
// InteractiveMode.renderSessionItems.
// This file installs those as two independently probed adapters, each of which throws
// when its own exact method is missing; fm-calm.ts catches that and skips only the
// affected adapter with a diagnostic instead of blocking Calm or Pi.
// The operational-user-row adapter owns the zero-height row and the canonical user-row
// origin the assistant layout adapter consumes. The transcript-replay adapter only marks
// the replay window; without it, replayed rows fall back to run scoping, which resolves
// to visible.
// Neither adapter changes message delivery.
import type { UserMessageComponent as PiUserMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import {
  beginCalmTranscriptReplay,
  endCalmTranscriptReplay,
  noteCalmTranscriptUserMessage,
} from "./fm-calm-assistant-layout.ts";
import { calmPresentationHides } from "./fm-calm-visibility.ts";
import { classifyFirstmateCurrentOperationalText } from "./fm-operational-input.ts";

type UserMessageConstructorArgs = ConstructorParameters<typeof PiUserMessageComponent>;
type UserMessageLike = {
  role: string;
  content: unknown;
};
type AddMessageOptions = {
  populateHistory?: boolean;
};
type InteractiveModePresentation = {
  chatContainer: {
    children: unknown[];
    addChild(component: PiUserMessageComponent): void;
  };
  editor: {
    addToHistory?(text: string): void;
  };
  getMarkdownThemeWithSettings(): UserMessageConstructorArgs[1];
  getUserMessageText(message: UserMessageLike): string;
  outputPad: number;
};
type InteractiveModePrototype = {
  addMessageToChat(
    this: InteractiveModePresentation,
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void;
  renderSessionItems(this: unknown, items: unknown[], options?: unknown): void;
};
type CalmOperationalUserLayoutPatch = {
  hidesOperationalInput: () => boolean;
  isOperationalInput: (text: string) => boolean;
};
type CalmTranscriptReplayPatch = {
  wrapped: true;
};

// Each symbol changes only when the closure it guards changes, so a compatible upgrade
// cannot double-patch a live process and an incompatible one cannot keep a stale closure
// installed under the same key.
const CALM_OPERATIONAL_USER_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-operational-user-layout:operational-ack-v2",
);
const CALM_TRANSCRIPT_REPLAY_PATCH = Symbol.for(
  "firstmate:calm-transcript-replay:v1",
);
const LEGACY_CALM_OPERATIONAL_PREFIX = "\u2063Supervisor escalate (";

function contentIsTextOnly(content: unknown): boolean {
  if (typeof content === "string") return true;
  if (!Array.isArray(content) || content.length === 0) return false;
  return content.every(
    (block) =>
      typeof block === "object" &&
      block !== null &&
      (block as { type?: unknown }).type === "text" &&
      typeof (block as { text?: unknown }).text === "string",
  );
}

export function installCalmOperationalUserLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmOperationalUserLayoutPatch | undefined;
  };
  const hidesOperationalInput = (): boolean => calmPresentationHides("synthetic-user");
  const isOperationalInput = (text: string): boolean => {
    if (!text.includes("\u2063")) return false;
    return (
      classifyFirstmateCurrentOperationalText(text) !== undefined ||
      text.startsWith(LEGACY_CALM_OPERATIONAL_PREFIX)
    );
  };
  const installed = registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH];
  if (installed) {
    installed.hidesOperationalInput = hidesOperationalInput;
    installed.isOperationalInput = isOperationalInput;
    return;
  }

  const patch: CalmOperationalUserLayoutPatch = {
    hidesOperationalInput,
    isOperationalInput,
  };
  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as InteractiveModePrototype;
  const originalAddMessageToChat = prototype.addMessageToChat;
  if (typeof originalAddMessageToChat !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.addMessageToChat");
  }

  const UserMessageComponent = PiCodingAgent.UserMessageComponent;
  if (typeof UserMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi UserMessageComponent");
  }
  class CalmOperationalUserMessageComponent extends UserMessageComponent {
    private readonly hasLeadingSpacer: boolean;

    constructor(
      text: UserMessageConstructorArgs[0],
      markdownTheme: UserMessageConstructorArgs[1],
      outputPad: number,
      hasLeadingSpacer: boolean,
    ) {
      super(text, markdownTheme, outputPad);
      this.hasLeadingSpacer = hasLeadingSpacer;
    }

    override render(width: number): string[] {
      if (patch.hidesOperationalInput()) return [];
      const lines = super.render(width);
      return this.hasLeadingSpacer ? ["", ...lines] : lines;
    }
  }

  prototype.addMessageToChat = function (
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void {
    if (message.role !== "user") {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    if (!contentIsTextOnly(message.content)) {
      noteCalmTranscriptUserMessage(false);
      originalAddMessageToChat.call(this, message, options);
      return;
    }
    const text = this.getUserMessageText(message);
    const isOperational = Boolean(text && patch.isOperationalInput(text));
    noteCalmTranscriptUserMessage(isOperational);
    if (!isOperational) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const component = new CalmOperationalUserMessageComponent(
      text,
      this.getMarkdownThemeWithSettings(),
      this.outputPad,
      this.chatContainer.children.length > 0,
    );
    this.chatContainer.addChild(component);
    if (options?.populateHistory) this.editor.addToHistory?.(text);
  };

  registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH] = patch;
}

export function installCalmTranscriptReplayWindow(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmTranscriptReplayPatch | undefined;
  };
  if (registry[CALM_TRANSCRIPT_REPLAY_PATCH]) return;

  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as InteractiveModePrototype;
  const originalRenderSessionItems = prototype.renderSessionItems;
  if (typeof originalRenderSessionItems !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.renderSessionItems");
  }

  prototype.renderSessionItems = function (
    this: unknown,
    items: unknown[],
    options?: unknown,
  ): void {
    beginCalmTranscriptReplay();
    try {
      originalRenderSessionItems.call(this, items, options);
    } finally {
      endCalmTranscriptReplay();
    }
  };

  registry[CALM_TRANSCRIPT_REPLAY_PATCH] = { wrapped: true };
}
