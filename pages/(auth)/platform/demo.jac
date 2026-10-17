"""Demo Console: reset the seeded scenario. Demo mode only, requires typed
confirmation - this is a destructive, consequential action."""

import from "sonner" { toast }
import from ....admin.store { admin_reset_demo }
import from ....identity.session { platform_status, PlatformStatus }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StateViews { LoadingRows }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ....components.ui.alert { Alert, AlertTitle, AlertDescription }
import from ....components.ui.alert_dialog {
    AlertDialog, AlertDialogTrigger, AlertDialogContent, AlertDialogHeader, AlertDialogTitle,
    AlertDialogDescription, AlertDialogFooter, AlertDialogAction, AlertDialogCancel
}
import from ....components.ui.input { Input }
import from ....components.ui.button { Button }
import from ....components.ui.badge { Badge }

def:pub DemoConsolePage() -> JsxPage {
    has status: PlatformStatus | None = None,
        loading: bool = True,
        confirm_text: str = "",
        resetting: bool = False;

    async can with entry {
        try {
            status = await platform_status();
        } except Exception {
            status = None;
        }
        loading = False;
    }

    async def do_reset {
        if confirm_text != "RESET DEMO" {
            toast.error("Type RESET DEMO exactly to confirm.");
            return;
        }
        resetting = True;
        try {
            result = await admin_reset_demo(confirm_text);
            if result.ok {
                toast.success(result.message);
                confirm_text = "";
            } else {
                toast.error(result.message or "Could not reset the demo.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        resetting = False;
    }

    if loading {
        return <div className="flex flex-col gap-4"><LoadingRows count={2} /></div>;
    }
    cfg = status;

    <div className="flex flex-col gap-6">
        <PageHeader title="Demo Console" description="Platform configuration and the seeded demo scenario." />

        {if cfg is not None {
            <Card>
                <CardHeader><CardTitle>Platform status</CardTitle></CardHeader>
                <CardContent className="flex flex-wrap gap-2">
                    <Badge variant={cfg.demo_mode and "outline" or "default"}>{cfg.demo_mode and "Demo mode" or "Production mode"}</Badge>
                    <Badge variant="secondary">{cfg.agent_label}</Badge>
                    <Badge variant="outline">Currency: {cfg.currency}</Badge>
                </CardContent>
            </Card>
            skip;
        }}

        {if cfg is not None and cfg.demo_mode {
            <Card className="border-destructive/40">
                <CardHeader>
                    <CardTitle>Reset demo scenario</CardTitle>
                    <CardDescription>Deletes every seeded and created record and re-seeds the fictional scenario. Other demo users re-link on their next sign-in.</CardDescription>
                </CardHeader>
                <CardContent>
                    <Alert variant="destructive">
                        <AlertTitle>This cannot be undone</AlertTitle>
                        <AlertDescription>All orders, shipments, inventory edits and accounts created since the last reset will be lost.</AlertDescription>
                    </Alert>
                </CardContent>
                <CardFooter className="flex items-center gap-2">
                    <Input placeholder="Type RESET DEMO" value={confirm_text} onChange={lambda (e: ChangeEvent) { confirm_text = e.target.value; }} className="w-56" />
                    <AlertDialog>
                        <AlertDialogTrigger asChild={True}><Button variant="destructive" disabled={confirm_text != "RESET DEMO"}>Reset demo</Button></AlertDialogTrigger>
                        <AlertDialogContent>
                            <AlertDialogHeader>
                                <AlertDialogTitle>Reset the demo scenario?</AlertDialogTitle>
                                <AlertDialogDescription>This permanently deletes all current MineFlow records and re-seeds the fictional scenario.</AlertDialogDescription>
                            </AlertDialogHeader>
                            <AlertDialogFooter>
                                <AlertDialogCancel>Cancel</AlertDialogCancel>
                                <AlertDialogAction disabled={resetting} onClick={do_reset}>Reset demo</AlertDialogAction>
                            </AlertDialogFooter>
                        </AlertDialogContent>
                    </AlertDialog>
                </CardFooter>
            </Card>
            skip;
        }}

        {if cfg is not None and not cfg.demo_mode {
            <Alert>
                <AlertTitle>Demo reset disabled</AlertTitle>
                <AlertDescription>This deployment is running in production mode.</AlertDescription>
            </Alert>
            skip;
        }}
    </div>
}
