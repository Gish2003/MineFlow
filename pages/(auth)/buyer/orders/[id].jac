import from "@jac/runtime" { useParams }
import from .OrderDetailShell { OrderDetailShell }

def:pub OrderDetailPage() -> JsxPage {
    params = useParams();
    order_id = params["id"];
    if not order_id {
        return <p className="p-8 text-sm text-muted-foreground">Order not found.</p>;
    }
    <OrderDetailShell orderId={order_id as str} />
}
