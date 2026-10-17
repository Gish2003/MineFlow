import from "@jac/runtime" { Outlet }
import from ....shell.RoleLayout { RoleLayout }

def:pub PlantLayout() -> JsxLayout {
    <RoleLayout role="STORE_MANAGER"><Outlet /></RoleLayout>
}
