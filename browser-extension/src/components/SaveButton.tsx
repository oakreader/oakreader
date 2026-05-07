import { Loader2, Check } from "lucide-react";

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
      <div className="flex items-center justify-center gap-2 rounded-full bg-success/10 h-9 px-4">
        <Check className="size-[14px] text-success" strokeWidth={2.5} />
        <span className="text-[13px] font-semibold text-success">Saved</span>
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
        className="flex w-full items-center justify-center gap-2 rounded-full bg-primary h-9 px-4 text-[13px] font-semibold text-primary-foreground transition-all duration-200 ease-in-out hover:brightness-110 active:scale-[0.98] disabled:opacity-40"
        disabled={disabled}
        onClick={onClick}
      >
        {isWorking && <Loader2 className="size-[14px] animate-spin" />}
        {buttonLabel}
      </button>
      {state === "error" && errorMessage && (
        <p className="text-center text-[11px] text-destructive">{errorMessage}</p>
      )}
    </div>
  );
}
