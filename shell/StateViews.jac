import from ..components.ui.skeleton { Skeleton }
import from ..components.ui.alert { Alert, AlertTitle, AlertDescription }
import from ..components.ui.button { Button }
import from ..components.ui.empty { Empty, EmptyHeader, EmptyMedia, EmptyTitle, EmptyDescription, EmptyContent }
import from "@hugeicons/react" { HugeiconsIcon }
import from "@hugeicons/core-free-icons" { Alert02Icon, InboxIcon }

def:pub LoadingRows(count: int = 3) -> JsxElement {
    <div className="flex flex-col gap-3">
        {for i in range(count) {
            <Skeleton key={str(i)} className="h-16 w-full rounded-xl" />
        }}
    </div>
}

def:pub ErrorState(message: str, onRetry: Callable[[], None] | None = None) -> JsxElement {
    <Alert variant="destructive">
        <HugeiconsIcon icon={Alert02Icon} strokeWidth={2} className="size-4" />
        <AlertTitle>Something went wrong</AlertTitle>
        <AlertDescription>
            <p>{message}</p>
            {onRetry and <Button size="sm" variant="outline" className="mt-2" onClick={lambda { onRetry(); }}>Try again</Button> or None}
        </AlertDescription>
    </Alert>
}

def:pub EmptyState(title: str, description: str = "", actionLabel: str = "", onAction: Callable[[], None] | None = None) -> JsxElement {
    <Empty>
        <EmptyHeader>
            <EmptyMedia variant="icon">
                <HugeiconsIcon icon={InboxIcon} strokeWidth={2} />
            </EmptyMedia>
            <EmptyTitle>{title}</EmptyTitle>
            {description and <EmptyDescription>{description}</EmptyDescription> or None}
        </EmptyHeader>
        {actionLabel and onAction and <EmptyContent><Button onClick={lambda { onAction(); }}>{actionLabel}</Button></EmptyContent> or None}
    </Empty>
}
