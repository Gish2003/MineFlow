import from ".components.ui.button" { Button }
import from ".components.ui.card" {
    Card, CardHeader, CardTitle, CardDescription, CardContent
}
import ".styles.global.css";

def:pub app() -> JsxElement {
    return <div className="min-h-screen bg-background text-foreground flex items-center justify-center p-6">
        <Card className="w-full max-w-md">
            <CardHeader>
                <CardTitle>Welcome to AI-hackathon</CardTitle>
                <CardDescription>A themed jac-shadcn starter.</CardDescription>
            </CardHeader>
            <CardContent className="flex gap-2">
                <Button>Get started</Button>
                <Button variant="outline">Docs</Button>
            </CardContent>
        </Card>
    </div>;
}
