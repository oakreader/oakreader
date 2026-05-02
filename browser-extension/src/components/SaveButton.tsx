import { Loader2, Check } from "lucide-react";

export type SaveState = "idle" | "capturing" | "saving" | "saved" | "error";

interface SaveButtonProps {
  state: SaveState;
  label: string;
  errorMessage?: string;
  onClick: () => void;
}

export function SaveButton({ state, label, errorMessage, onClick }: SaveButtonProps) {
  if (state === "saved") {
    return (
      <div className="flex items-center justify-center gap-2 rounded-lg bg-success/10 py-2.5 px-4">
        <Check className="size-4 text-success" />
        <span className="text-[13px] font-medium text-success">Saved</span>
      </div>
    );
  }

  const isWorking = state === "capturing" || state === "saving";
  const disabled = isWorking;

  let buttonLabel: string;
  if (state === "capturing") {
    buttonLabel = "Capturing page\u2026";
  } else if (state === "saving") {
    buttonLabel = label;
  } else {
    buttonLabel = "Save to Research";
  }

  return (
    <div className="space-y-2">
      <button
        type="button"
        className="flex w-full items-center justify-center gap-2 rounded-lg bg-primary py-2.5 px-4 text-[13px] font-semibold text-primary-foreground transition-opacity hover:opacity-90 disabled:opacity-50"
        disabled={disabled}
        onClick={onClick}
      >
        {isWorking && <Loader2 className="size-4 animate-spin" />}
        {buttonLabel}
      </button>
      {state === "error" && errorMessage && (
        <p className="text-center text-[11px] text-destructive">{errorMessage}</p>
      )}
    </div>
  );
}
