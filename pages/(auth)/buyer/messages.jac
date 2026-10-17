"""Messages: in-app threads with the driver assigned to each active shipment."""

import from ....messaging.store { my_threads, shipment_messages, send_message, ThreadSummary, MessageView }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_ago }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardContent }
import from ....components.ui.input { Input }
import from ....components.ui.button { Button }
import from ....components.ui.scroll_area { ScrollArea }
import from ....components.ui.separator { Separator }

def:pub MessagesPage() -> JsxPage {
    has threads: list[ThreadSummary] = [],
        loading: bool = True,
        error: str = "",
        active_id: str = "",
        thread_messages: list[MessageView] = [],
        can_send: bool = False,
        msg_text: str = "";

    poll_seq = usePoll(15000);

    async def load_threads {
        try {
            result = await my_threads(poll_seq);
            if result.ok {
                threads = result.threads;
            } else {
                error = result.message or "Could not load your messages.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async def open_thread(shipment_id: str) {
        active_id = shipment_id;
        try {
            result = await shipment_messages(shipment_id, poll_seq);
            if result.ok {
                thread_messages = result.messages;
                can_send = result.can_send;
            }
        } except Exception {
            thread_messages = [];
        }
    }

    async can with [poll_seq] entry {
        await load_threads();
        if active_id {
            await open_thread(active_id);
        }
    }

    async def send_msg {
        if not active_id or not msg_text.strip() {
            return;
        }
        try {
            await send_message(active_id, msg_text);
            msg_text = "";
            await open_thread(active_id);
        } except Exception {
            _ = None;
        }
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Messages" description="In-app conversations with drivers on your active deliveries." />

        {if loading {
            <LoadingRows count={4} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load_threads} />
            skip;
        }}
        {if not loading and not error and len(threads) == 0 {
            <EmptyState title="No conversations yet" description="A thread opens automatically once a driver is assigned to your delivery." />
            skip;
        }}

        {if len(threads) > 0 {
            <div className="grid grid-cols-1 gap-4 md:grid-cols-[320px_1fr]">
                <Card className="p-0">
                    <ScrollArea className="h-[520px]">
                        <div className="flex flex-col">
                            {for t in threads {
                                <button
                                    key={t.shipment_id}
                                    onClick={lambda { open_thread(t.shipment_id); }}
                                    className={"flex flex-col gap-1 border-b p-3 text-left text-sm hover:bg-muted " + ("bg-accent" if active_id == t.shipment_id else "")}
                                >
                                    <div className="flex items-center justify-between">
                                        <span className="font-medium">{t.title}</span>
                                        <StatusChip status={t.status} />
                                    </div>
                                    <span className="truncate text-muted-foreground">{t.last_body or "No messages yet"}</span>
                                    <span className="text-xs text-muted-foreground">{fmt_ago(t.last_at)}</span>
                                </button>
                            }}
                        </div>
                    </ScrollArea>
                </Card>
                <Card>
                    <CardContent className="flex h-[520px] flex-col gap-3 p-4">
                        {if not active_id {
                            <p className="text-sm text-muted-foreground">Choose a conversation on the left.</p>
                            skip;
                        }}
                        {if active_id {
                            <ScrollArea className="flex-1">
                                <div className="flex flex-col gap-2 pr-2">
                                    {for m in thread_messages {
                                        <div key={m.id} className={"max-w-[80%] rounded-lg p-2 text-sm " + ("self-end bg-primary text-primary-foreground" if m.mine else "self-start bg-muted")}>
                                            <p className="text-xs opacity-70">{m.sender_name}</p>
                                            <p>{m.body}</p>
                                        </div>
                                    }}
                                </div>
                            </ScrollArea>
                            <Separator />
                            <div className="flex gap-2">
                                <Input disabled={not can_send} value={msg_text} onChange={lambda (e: ChangeEvent) { msg_text = e.target.value; }} placeholder={can_send and "Message the driver…" or "Messaging opens once a driver is assigned."} />
                                <Button disabled={not can_send} onClick={send_msg}>Send</Button>
                            </div>
                            skip;
                        }}
                    </CardContent>
                </Card>
            </div>
            skip;
        }}
    </div>
}
