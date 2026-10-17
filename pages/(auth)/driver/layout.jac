import from "@jac/runtime" { Outlet }
import from ....shell.RoleLayout { RoleLayout }

def:pub DriverLayout() -> JsxLayout {
    <RoleLayout role="DRIVER"><Outlet /></RoleLayout>
}
