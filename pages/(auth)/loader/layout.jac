import from "@jac/runtime" { Outlet }
import from ....shell.RoleLayout { RoleLayout }

def:pub LoaderLayout() -> JsxLayout {
    <RoleLayout role="LOADER"><Outlet /></RoleLayout>
}
