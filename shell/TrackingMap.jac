"""Simulated tracking map. Route/ETA are estimates (straight-line x road
factor), never presented as live GPS unless the position actually came from
a DEVICE ping - labelled accordingly by the caller via `simulated`."""

import from "react-leaflet" { MapContainer, TileLayer, CircleMarker, Polyline }
import "leaflet/dist/leaflet.css";

def:pub TrackingMap(
    plantLat: float, plantLng: float, destLat: float, destLng: float,
    route: list[list[float]] = [], trail: list[list[float]] = [],
    lastLat: float = 0.0, lastLng: float = 0.0, hasFix: bool = False, simulated: bool = True
) -> JsxElement {
    center: list[float] = [(plantLat + destLat) / 2.0, (plantLng + destLng) / 2.0];
    <div className="overflow-hidden rounded-lg border" style={{"height": "320px", "width": "100%"}}>
        <MapContainer center={center} zoom={9} scrollWheelZoom={False} style={{"height": "100%", "width": "100%"}}>
            <TileLayer
                attribution={simulated and "Simulated route · &copy; OpenStreetMap contributors" or "&copy; OpenStreetMap contributors"}
                url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
            />
            <CircleMarker center={[plantLat, plantLng]} radius={8} pathOptions={{"color": "#15803d", "fillColor": "#15803d", "fillOpacity": 1}} />
            <CircleMarker center={[destLat, destLng]} radius={8} pathOptions={{"color": "#1d4ed8", "fillColor": "#1d4ed8", "fillOpacity": 1}} />
            {len(route) > 1 and <Polyline positions={route} pathOptions={{"color": "#94a3b8", "dashArray": "6 6", "weight": 3}} /> or None}
            {len(trail) > 1 and <Polyline positions={trail} pathOptions={{"color": "#b45309", "weight": 4}} /> or None}
            {hasFix and <CircleMarker center={[lastLat, lastLng]} radius={7} pathOptions={{"color": "#b45309", "fillColor": "#f59e0b", "fillOpacity": 1}} /> or None}
        </MapContainer>
    </div>
}
