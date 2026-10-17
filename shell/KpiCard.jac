import from ..components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent }
import from ..components.ui.badge { Badge }

def:pub KpiCard(label: str, value: str, hint: str = "", tone: str = "default", children: any = None) -> JsxElement {
    <Card>
        <CardHeader>
            <div className="flex items-center justify-between">
                <CardDescription>{label}</CardDescription>
                {children}
            </div>
            <CardTitle className="text-3xl font-semibold tabular-nums">{value}</CardTitle>
            {hint and <Badge variant={tone if tone != "default" else "outline"} className="mt-2 w-fit">{hint}</Badge> or None}
        </CardHeader>
    </Card>
}
