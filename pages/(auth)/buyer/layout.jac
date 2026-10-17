import from "@jac/runtime" { Outlet }
import from ....shell.RoleLayout { RoleLayout }

def:pub BuyerLayout() -> JsxLayout {
    <RoleLayout role="BUYER"><Outlet /></RoleLayout>
}
