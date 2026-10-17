import from ..components.ui.popover { Popover, PopoverTrigger, PopoverContent }
import from ..components.ui.button { Button }
import from ..components.ui.badge { Badge }
import from ..components.ui.scroll_area { ScrollArea }
import from ..components.ui.empty { Empty, EmptyHeader, EmptyMedia, EmptyTitle }
import from ..messaging.store { my_notifications, mark_notifications_read, NotificationView }
import from ..hooks.usePoll { usePoll }
import from .format { fmt_ago }
import from "@jac/runtime" { useNavigate }
import from "@hugeicons/react" { HugeiconsIcon }
import from "@hugeicons/core-free-icons" { Notification03Icon, InboxIcon }

def:pub NotificationBell() -> JsxElement {
    has items: list[NotificationView] = [],
        unread: int = 0,
        open: bool = False;

    poll_seq = usePoll(20000);
    nav = useNavigate();

    async can with [poll_seq] entry {
        result = await my_notifications(poll_seq);
        if result.ok {
            items = result.items;
            unread = result.unread;
        }
    }

    async def handle_open(next_open: bool) {
        open = next_open;
        if next_open and unread > 0 {
            await mark_notifications_read([]);
            unread = 0;
        }
    }

    def handle_click(n: NotificationView) {
        open = False;
        if n.link {
            nav(n.link);
        }
    }

    <Popover open={open} onOpenChange={handle_open}>
        <PopoverTrigger asChild={True}>
            <Button variant="ghost" size="icon" className="relative">
                <HugeiconsIcon icon={Notification03Icon} strokeWidth={2} className="size-4" />
                {unread > 0 and <Badge variant="destructive" className="absolute -right-1 -top-1 h-5 min-w-5 justify-center px-1">{str(unread)}</Badge> or None}
            </Button>
        </PopoverTrigger>
        <PopoverContent className="w-80 p-0" align="end">
            <div className="flex items-center justify-between border-b p-3">
                <span className="text-sm font-semibold">Notifications</span>
            </div>
            {if len(items) == 0 {
                <Empty>
                    <EmptyHeader>
                        <EmptyMedia variant="icon"><HugeiconsIcon icon={InboxIcon} strokeWidth={2} /></EmptyMedia>
                        <EmptyTitle>No notifications yet</EmptyTitle>
                    </EmptyHeader>
                </Empty>
                skip;
            }}
            <ScrollArea className="max-h-80">
                <div className="flex flex-col">
                    {for n in items {
                        <button
                            key={n.id}
                            onClick={lambda { handle_click(n); }}
                            className={"flex flex-col gap-0.5 border-b p-3 text-left text-sm last:border-b-0 hover:bg-muted " + ("" if n.read else "bg-accent/40")}
                        >
                            <span className="font-medium">{n.title}</span>
                            <span className="text-muted-foreground">{n.body}</span>
                            <span className="text-xs text-muted-foreground">{fmt_ago(n.at)}</span>
                        </button>
                    }}
                </div>
            </ScrollArea>
        </PopoverContent>
    </Popover>
}
