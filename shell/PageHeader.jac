import from ..components.ui.badge { Badge }

def:pub PageHeader(title: str, description: str = "", demo_note: str = "", children: any = None) -> JsxElement {
    <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
            <h1 className="text-balance text-2xl font-bold tracking-tight">{title}</h1>
            {description and <p className="mt-1 text-sm text-muted-foreground">{description}</p> or None}
            {demo_note and <Badge variant="outline" className="mt-2">{demo_note}</Badge> or None}
        </div>
        {children and <div className="flex shrink-0 items-center gap-2">{children}</div> or None}
    </div>
}
