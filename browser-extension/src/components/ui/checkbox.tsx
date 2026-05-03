"use client"

import { Checkbox as CheckboxPrimitive } from "@base-ui/react/checkbox"

import { cn } from "@/src/lib/utils"
import { CheckIcon } from "lucide-react"

function Checkbox({ className, ...props }: CheckboxPrimitive.Root.Props) {
  return (
    <CheckboxPrimitive.Root
      data-slot="checkbox"
      className={cn(
        "peer relative flex size-3.5 shrink-0 items-center justify-center rounded-[4px] border-[1.5px] border-tertiary/60 transition-all duration-200 ease-in-out outline-none disabled:cursor-not-allowed disabled:opacity-40 data-checked:border-primary data-checked:bg-primary data-checked:text-primary-foreground focus-visible:ring-2 focus-visible:ring-primary/30",
        className
      )}
      {...props}
    >
      <CheckboxPrimitive.Indicator
        data-slot="checkbox-indicator"
        className="grid place-content-center text-current transition-none [&>svg]:size-2.5 [&>svg]:stroke-[3]"
      >
        <CheckIcon />
      </CheckboxPrimitive.Indicator>
    </CheckboxPrimitive.Root>
  )
}

export { Checkbox }
