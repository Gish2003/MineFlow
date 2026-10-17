"""MineFlow AI - entry module.

Server side: importing each feature's endpoint module makes the app compile it,
which registers its `def:pub` / `def:protect` endpoints. Client side: `app`
wraps the file-based router from `pages/`.
"""

import from identity.session {
    whoami, claim_demo_persona, platform_status, demo_personas, redeem_invite,
    redeem_bootstrap_admin
}

import from ".components.ui.button" { Button }
import from ".components.ui.card" {
    Card, CardHeader, CardTitle, CardDescription, CardContent
}
import ".styles.global.css";

def:pub app() -> JsxElement {
    return <div className="min-h-screen bg-background text-foreground flex items-center justify-center p-6">
        <Card className="w-full max-w-md">
            <CardHeader>
                <CardTitle>MineFlow AI</CardTitle>
                <CardDescription>Mineral ordering, dispatch and delivery.</CardDescription>
            </CardHeader>
            <CardContent className="flex gap-2">
                <Button>Get started</Button>
            </CardContent>
        </Card>
    </div>;
}
