import from "@jac/runtime" { Outlet }
import from ....shell.RoleLayout { RoleLayout }

def:pub DispatchLayout() -> JsxLayout {
    <RoleLayout role="DISPATCHER"><Outlet /></RoleLayout>
}
