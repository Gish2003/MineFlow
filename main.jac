"""MineFlow AI - entry module.

Server side: importing each feature's endpoint module makes the app compile it,
which registers its `def:pub` / `def:protect` endpoints. Client side: `app`
wraps the file-based router from `pages/`.
"""

import from identity.session {
    whoami, claim_demo_persona, platform_status, demo_personas, redeem_invite,
    redeem_bootstrap_admin
}
import from orders.store { buyer_catalog, create_order, request_recommendations }
import from dispatch.store { dispatch_queue, approve_dispatch }
import from dispatch.exceptions { exceptions_list, run_recovery }
import from delivery.store { driver_home, respond_offer }
import from delivery.tracking { get_tracking, report_location }
import from loading.store { loader_home, finish_loading }
import from evidence.store { upload_evidence, get_evidence_file }
import from claims.store { claims_list, resolve_claim }
import from messaging.store { shipment_messages, my_notifications }
import from payments.ledger { ledger_entries, set_payment_status }

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
