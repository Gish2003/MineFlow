import from ..components.ui.badge { Badge }
import from .status { status_variant, status_label }

def:pub StatusChip(status: str, className: str = "") -> JsxElement {
    <Badge variant={status_variant(status)} className={className}>{status_label(status)}</Badge>
}
