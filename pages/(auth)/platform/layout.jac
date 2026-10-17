import from "@jac/runtime" { Outlet }
import from ....shell.RoleLayout { RoleLayout }

def:pub PlatformLayout() -> JsxLayout {
    <RoleLayout role="ADMIN"><Outlet /></RoleLayout>
}
