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
import from inventory.store { manager_plants, plant_detail }
import from inventory.spreadsheet { preview_import, export_inventory }
import from admin.store { admin_directory, admin_reset_demo }

import from .components.ui.tooltip { TooltipProvider }
import from .components.ui.sonner { Toaster }
import ".styles.global.css";

"""Global providers around the file-based router tree from pages/."""
def:pub app(children: any) -> JsxElement {
    <TooltipProvider>
        {children}
        <Toaster position="top-right" />
    </TooltipProvider>
}
