"""Shared dashboard shell: sidebar navigation (role-scoped), header with the
demo badge, agent-mode label and notification bell, and the main content
slot. Rendered once per role by that role's pages/(auth)/<role>/layout.jac."""

import from ..components.ui.sidebar {
    SidebarProvider, Sidebar, SidebarTrigger, SidebarInset, SidebarHeader, SidebarFooter,
    SidebarContent, SidebarGroup, SidebarGroupLabel, SidebarGroupContent, SidebarMenu,
    SidebarMenuItem, SidebarMenuButton
}
import from ..components.ui.separator { Separator }
import from ..components.ui.avatar { Avatar, AvatarFallback }
import from ..components.ui.badge { Badge }
import from ..components.ui.button { Button }
import from .NotificationBell { NotificationBell }
import from "@jac/runtime" { Link, useLocation, jacLogout, useNavigate }
import from "@hugeicons/react" { HugeiconsIcon }
import from "@hugeicons/core-free-icons" {
    TruckDeliveryIcon, AddCircleIcon, Mail01Icon, AlertCircleIcon, WarehouseIcon,
    Package02Icon, FileImportIcon, Calendar01Icon, Factory01Icon, Clock01Icon,
    DashboardSquare01Icon, CheckListIcon, DashboardCircleIcon, TruckIcon, AlertDiamondIcon,
    DocumentValidationIcon, PackageProcessIcon, MoneyBag02Icon, UserMultipleIcon,
    Building06Icon, Mail02Icon, Shield01Icon, LogoutCircle01Icon
}

glob NAV: dict[str, list[dict[str, any]]] = {
    "BUYER": [
        {"label": "My Orders", "path": "/buyer", "icon": Package02Icon},
        {"label": "Create Order", "path": "/buyer/create", "icon": AddCircleIcon},
        {"label": "Active Deliveries", "path": "/buyer/deliveries", "icon": TruckDeliveryIcon},
        {"label": "Messages", "path": "/buyer/messages", "icon": Mail01Icon},
        {"label": "Claims", "path": "/buyer/claims", "icon": AlertCircleIcon}
    ],
    "STORE_MANAGER": [
        {"label": "Plant Inventory", "path": "/plant", "icon": WarehouseIcon},
        {"label": "Stock Lots & Quality", "path": "/plant/lots", "icon": Package02Icon},
        {"label": "Import / Export", "path": "/plant/import_export", "icon": FileImportIcon},
        {"label": "Reservations", "path": "/plant/reservations", "icon": Calendar01Icon},
        {"label": "Production & Delays", "path": "/plant/schedule", "icon": Factory01Icon},
        {"label": "Loading Schedule", "path": "/plant/loading", "icon": Clock01Icon},
        {"label": "Claims", "path": "/plant/claims", "icon": AlertCircleIcon}
    ],
    "DISPATCHER": [
        {"label": "Operations Overview", "path": "/dispatch", "icon": DashboardSquare01Icon},
        {"label": "Order Queue", "path": "/dispatch/queue", "icon": CheckListIcon},
        {"label": "Dispatch Board", "path": "/dispatch/board", "icon": DashboardCircleIcon},
        {"label": "Loading Schedule", "path": "/dispatch/loading", "icon": Clock01Icon},
        {"label": "Drivers & Vehicles", "path": "/dispatch/fleet", "icon": TruckIcon},
        {"label": "Exceptions", "path": "/dispatch/exceptions", "icon": AlertDiamondIcon},
        {"label": "Claims", "path": "/dispatch/claims", "icon": AlertCircleIcon},
        {"label": "Audit Trail", "path": "/dispatch/audit", "icon": DocumentValidationIcon}
    ],
    "LOADER": [
        {"label": "My Loading Jobs", "path": "/loader", "icon": PackageProcessIcon},
        {"label": "Payment Status", "path": "/loader/payments", "icon": MoneyBag02Icon}
    ],
    "DRIVER": [
        {"label": "Offers & Assignments", "path": "/driver", "icon": TruckDeliveryIcon},
        {"label": "Payouts", "path": "/driver/payouts", "icon": MoneyBag02Icon}
    ],
    "ADMIN": [
        {"label": "Directory", "path": "/platform", "icon": UserMultipleIcon},
        {"label": "Organizations & Plants", "path": "/platform/orgs", "icon": Building06Icon},
        {"label": "Invites", "path": "/platform/invites", "icon": Mail02Icon},
        {"label": "Demo Console", "path": "/platform/demo", "icon": Shield01Icon}
    ]
};

glob ROLE_LABELS: dict[str, str] = {
    "BUYER": "Mineral Buyer", "STORE_MANAGER": "Store Manager", "DISPATCHER": "Dispatcher",
    "LOADER": "Loader", "DRIVER": "Driver", "ADMIN": "Platform Administrator"
};

def initials(name: str) -> str {
    parts = [p for p in name.split(" ") if p];
    if len(parts) == 0 {
        return "?";
    }
    if len(parts) == 1 {
        return parts[0][:2].upper();
    }
    return (parts[0][0] + parts[-1][0]).upper();
}

def:pub RoleShell(
    role: str, display_name: str, org_name: str, demo_mode: bool, agent_label: str,
    children: any = None
) -> JsxElement {
    loc = useLocation();
    nav = useNavigate();
    items = NAV[role] or [];

    def do_logout {
        jacLogout();
        nav("/login");
    }

    <SidebarProvider>
        <Sidebar collapsible="offcanvas">
            <SidebarHeader>
                <div className="flex items-center gap-2 px-2 py-1.5">
                    <div className="flex size-8 items-center justify-center rounded-lg bg-primary text-primary-foreground">
                        <HugeiconsIcon icon={TruckDeliveryIcon} strokeWidth={2} className="size-4" />
                    </div>
                    <div className="flex flex-col leading-tight">
                        <span className="text-sm font-semibold">MineFlow AI</span>
                        <span className="text-xs text-muted-foreground">{ROLE_LABELS[role] or role}</span>
                    </div>
                </div>
            </SidebarHeader>
            <SidebarContent>
                <SidebarGroup>
                    <SidebarGroupLabel>Workspace</SidebarGroupLabel>
                    <SidebarGroupContent>
                        <SidebarMenu>
                            {for item in items {
                                <SidebarMenuItem key={item["path"] as str}>
                                    <SidebarMenuButton asChild={True} isActive={loc.pathname == item["path"]}>
                                        <Link to={item["path"] as str}>
                                            <HugeiconsIcon icon={item["icon"]} strokeWidth={2} className="size-4" />
                                            <span>{item["label"] as str}</span>
                                        </Link>
                                    </SidebarMenuButton>
                                </SidebarMenuItem>
                            }}
                        </SidebarMenu>
                    </SidebarGroupContent>
                </SidebarGroup>
            </SidebarContent>
            <SidebarFooter>
                <div className="flex items-center gap-2 px-2 py-1.5">
                    <Avatar className="size-8">
                        <AvatarFallback>{initials(display_name)}</AvatarFallback>
                    </Avatar>
                    <div className="flex min-w-0 flex-col leading-tight">
                        <span className="truncate text-sm font-medium">{display_name}</span>
                        <span className="truncate text-xs text-muted-foreground">{org_name}</span>
                    </div>
                    <Button variant="ghost" size="icon-sm" className="ml-auto" onClick={do_logout} title="Sign out">
                        <HugeiconsIcon icon={LogoutCircle01Icon} strokeWidth={2} className="size-4" />
                    </Button>
                </div>
            </SidebarFooter>
        </Sidebar>
        <SidebarInset>
            <header className="flex h-14 items-center gap-2 border-b pl-4 pr-4">
                <SidebarTrigger />
                <Separator orientation="vertical" className="mr-2 h-4" />
                <span className="text-sm font-medium text-muted-foreground">MineFlow AI</span>
                <div className="ml-auto flex items-center gap-2">
                    {demo_mode and <Badge variant="outline">Demo data</Badge> or None}
                    <Badge variant="secondary">{agent_label}</Badge>
                    <NotificationBell />
                </div>
            </header>
            <main className="flex flex-1 flex-col gap-6 pt-6 pb-6 pl-6 pr-6">{children}</main>
        </SidebarInset>
    </SidebarProvider>
}
