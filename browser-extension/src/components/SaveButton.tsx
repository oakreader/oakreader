import { ArrowRight, Check, Loader2 } from "lucide-react";

export type SaveState = "idle" | "capturing" | "saving" | "saved" | "error";

interface SaveButtonProps {
  state: SaveState;
  label: string;
  capturingLabel?: string;
  errorMessage?: string;
  onClick: () => void;
}

export function SaveButton({ state, label, capturingLabel, errorMessage, onClick }: SaveButtonProps) {
  if (state === "saved") {
    return (
      <div className="oak-success-card flex items-center justify-center gap-2 h-11 px-4">
        <Check className="size-[15px] text-success" strokeWidth={2.7} />
        <span className="text-[13px] font-semibold text-success">Saved to OakReader</span>
      </div>
    );
  }

  const isWorking = state === "capturing" || state === "saving";
  const disabled = isWorking;

  let buttonLabel: string;
  if (state === "capturing") {
    buttonLabel = capturingLabel ?? "Capturing page\u2026";
  } else if (state === "saving") {
    buttonLabel = label;
  } else {
    buttonLabel = "Save to OakReader";
  }

  return (
    <div className="space-y-2">
      <button
        type="button"
        className="oak-primary-button flex w-full items-center justify-center gap-2 h-11 px-4 text-[13px] font-semibold text-primary-foreground transition-all duration-200 ease-in-out hover:brightness-110 active:scale-[0.985] disabled:opacity-50"
        disabled={disabled}
        onClick={onClick}
      >
        {isWorking ? (
          <Loader2 className="size-[15px] animate-spin" />
        ) : (
          <ArrowRight className="size-[15px]" strokeWidth={2.5} />
        )}
        {buttonLabel}
      </button>
      {state === "error" && errorMessage && (
        <p className="text-center text-[11px] text-destructive">{errorMessage}</p>
      )}
    </div>
  );
}
