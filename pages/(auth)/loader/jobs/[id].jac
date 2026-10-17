import from "@jac/runtime" { useParams }
import from .LoaderJobShell { LoaderJobShell }

def:pub LoaderJobPage() -> JsxPage {
    params = useParams();
    shipment_id = params["id"];
    if not shipment_id {
        return <p className="p-8 text-sm text-muted-foreground">Job not found.</p>;
    }
    <LoaderJobShell shipmentId={shipment_id as str} />
}
