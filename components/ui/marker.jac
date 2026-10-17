import from "class-variance-authority" { cva }
import from "radix-ui" { Slot }
import from ...lib.utils { cn }

glob _markerVariants: any = cva(
         "gap-2 text-sm text-muted-foreground [a]:hover:text-foreground [a]:underline-offset-3 [a]:underline [&_svg:not([class*='size-'])]:size-4 min-h-4 text-left group/marker relative flex w-full items-center",
         {
             "variants": {
                 "variant": {
                     "default": "gap-2 text-sm text-muted-foreground [a]:hover:text-foreground [a]:underline-offset-3 [a]:underline [&_svg:not([class*='size-'])]:size-4 min-h-4 text-left-variant-default",
                     "separator": "before:h-px before:min-w-0 before:flex-1 before:bg-border after:h-px after:min-w-0 after:flex-1 after:bg-border before:mr-1 after:ml-1",
                     "border": "border-b border-border pb-2"
                 }
             }
         }
     ),
     _markerExcludeKeys: list[str] = ["className", "variant", "asChild", "children"];

def:pub Marker(props: any) -> JsxElement {
    variant = props["variant"] or "default";
    asChild = props["asChild"] or False;
    computedClass = cn(
        _markerVariants.call(
            None, {"variant": variant, "className": props["className"]}
        )
    );

    restProps = {};
    for key in Object.keys(props) {
        if key not in _markerExcludeKeys {
            restProps[key] = props[key];
        }
    }

    if asChild {
        return
            <Slot.Root
                data-slot="marker"
                data-variant={variant}
                className={computedClass}
                {**restProps}
            >
                {props["children"]}
            </Slot.Root>;
    }
    <div
        data-slot="marker"
        data-variant={variant}
        className={computedClass}
        {**restProps}
    >
        {props["children"]}
    </div>
}

def:pub MarkerIcon(props: any) -> JsxElement {
    attrs: dict[str, any] = {** props};
    <span
        {**attrs}
        data-slot="marker-icon"
        aria-hidden="true"
        className={cn("size-4 [&_svg:not([class*='size-'])]:size-4 shrink-0", props["className"])}
    />
}

def:pub MarkerContent(props: any) -> JsxElement {
    attrs: dict[str, any] = {** props};
    <span
        {**attrs}
        data-slot="marker-content"
        className={cn("group-data-[variant=separator]/marker:flex-none group-data-[variant=separator]/marker:text-center *:[a]:hover:text-foreground *:[a]:underline *:[a]:underline-offset-3 min-w-0 wrap-break-word", props["className"])}
    />
}

def:pub markerVariants -> any {
    return _markerVariants;
}
