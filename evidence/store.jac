"""Operational evidence: loading photos, load tickets, unloading/proof-of-delivery
photos, delivery notes, quality certificates and claim evidence.

Who may upload what is enforced here; files are validated (type, size, base64)
and stored apart from their metadata. Downloads re-check visibility of the
owning record. Uploading evidence never changes a delivery status by itself.
"""

import base64;
import binascii;
import from core.model { DomainNode, Evidence, HasEvidence, EvidenceBlob, HasBlob, Shipment, Claim, QualityRecord }
import from core.enums { EvidenceKind, ShipmentStatus, Role, ClaimStatus }
import from core.hub { get_shipment, get_claim, get_evidence, blob_of, fetch, get_lot }
import from core.access {
    AppError, current_caller, Caller, can_view_shipment, can_view_claim, manages_plant,
    not_found, invalid, deny, bad_state, dispatcher_covers_plant
}
import from core.views { ActionResult, EvidenceView, EvidenceFile }
import from core.audit { audit }
import from core.config { settings }
import from core.util { now, sha256_hex, clean_text }

glob ALLOWED_MIME: list[str] = ["image/jpeg", "image/png", "image/webp", "application/pdf"];

def evidence_of(owner: DomainNode) -> list[Evidence] {
    return sorted([owner ->:HasEvidence:-> [?:Evidence]], key=lambda (e: Evidence) { e.created_at; });
}

def evidence_view(e: Evidence) -> EvidenceView {
    return EvidenceView(
        id=jid(e), kind=str(e.kind), filename=e.filename, mime=e.mime, size_bytes=e.size_bytes,
        uploaded_by_name=e.uploaded_by_name, uploaded_role=e.uploaded_role, note=e.note, created_at=e.created_at
    );
}

def evidence_views(owner: DomainNode) -> list[EvidenceView] {
    return [evidence_view(e) for e in evidence_of(owner)];
}

def count_of_kind(owner: DomainNode, kind: EvidenceKind) -> int {
    return len([e for e in evidence_of(owner) if e.kind == kind]);
}

def _quality_record(qid: str) -> QualityRecord | None {
    n = fetch(qid, QualityRecord);
    return None if n is None else n as QualityRecord;
}

"""Resolve the owner and check the caller may attach this kind of evidence."""
def _upload_target(c: Caller, owner_type: str, owner_id: str, kind: EvidenceKind) -> DomainNode {
    if owner_type == "SHIPMENT" {
        sh = get_shipment(owner_id);
        if sh is None or not can_view_shipment(c, sh) {
            raise not_found("Shipment");
        }
        if kind in [EvidenceKind.UNLOADING_PHOTO, EvidenceKind.DELIVERY_NOTE] {
            if not (c.has_role(Role.DRIVER) and sh.driver_id == c.account_id) {
                raise deny("Only the assigned driver can upload unloading evidence.");
            }
            if sh.status not in [ShipmentStatus.IN_TRANSIT, ShipmentStatus.DELIVERED] {
                raise bad_state("Unloading evidence can be added once the truck is in transit or delivered.");
            }
            return sh;
        }
        if kind in [EvidenceKind.LOADING_PHOTO, EvidenceKind.LOAD_TICKET] {
            if not (c.has_role(Role.LOADER) and sh.loader_id == c.account_id) {
                raise deny("Only the assigned loader can upload loading evidence.");
            }
            if sh.status not in [ShipmentStatus.LOADING, ShipmentStatus.LOADED] {
                raise bad_state("Loading evidence can be added while loading or right after.");
            }
            return sh;
        }
        raise invalid("That evidence type does not belong to a shipment.");
    }
    if owner_type == "CLAIM" {
        cl = get_claim(owner_id);
        if cl is None or not can_view_claim(c, cl) {
            raise not_found("Claim");
        }
        if kind != EvidenceKind.CLAIM_EVIDENCE {
            raise invalid("Claims accept claim evidence only.");
        }
        if cl.status in [ClaimStatus.RESOLVED, ClaimStatus.REJECTED] {
            raise bad_state("The claim is closed.");
        }
        if not (c.has_role(Role.BUYER) or c.has_role(Role.DISPATCHER) or c.has_role(Role.STORE_MANAGER)) {
            raise deny("Not allowed to add claim evidence.");
        }
        return cl;
    }
    if owner_type == "QUALITY" {
        q = _quality_record(owner_id);
        lot = get_lot(q.lot_id) if q is not None else None;
        if q is None or lot is None or not manages_plant(c, lot.plant_id) {
            raise not_found("Quality record");
        }
        if kind != EvidenceKind.QUALITY_CERTIFICATE {
            raise invalid("Quality records accept certificates only.");
        }
        return q;
    }
    raise invalid("Unknown evidence owner type.");
}

def:protect upload_evidence(owner_type: str, owner_id: str, kind: str, filename: str, mime: str, data_b64: str, note: str = "") -> ActionResult {
    try {
        c = current_caller();
        try {
            ek = EvidenceKind(kind);
        } except ValueError {
            raise invalid("Unknown evidence type.");
        }
        if mime not in ALLOWED_MIME {
            raise invalid("Only JPEG, PNG, WEBP images or PDF documents are accepted.");
        }
        raw = data_b64.split(",", 1)[1] if data_b64.startswith("data:") else data_b64;
        try {
            data = base64.b64decode(raw, validate=True);
        } except (binascii.Error, ValueError) {
            raise invalid("The file could not be decoded.");
        }
        if len(data) == 0 {
            raise invalid("The file is empty.");
        }
        if len(data) > settings().max_upload_bytes {
            raise invalid("The file is larger than the " + str(settings().max_upload_bytes // 1000000) + " MB limit.");
        }
        owner = _upload_target(c, owner_type, owner_id, ek);
        name = clean_text(filename, 120).replace("/", "_").replace("\\", "_") or "evidence";
        ev = Evidence(
            kind=ek, owner_type=owner_type, owner_id=owner_id, filename=name, mime=mime,
            size_bytes=len(data), sha256=sha256_hex(data), uploaded_by=c.account_id,
            uploaded_by_name=c.account.display_name, uploaded_role=str(c.account.role),
            note=clean_text(note, 300), created_at=now()
        );
        owner +>:HasEvidence():+> ev;
        ev +>:HasBlob():+> EvidenceBlob(data_b64=base64.b64encode(data).decode("ascii"));
        audit(c, "EVIDENCE_UPLOADED", owner_type, owner_id, kind + " " + name + " (" + str(len(data)) + " bytes)");
        return ActionResult(ok=True, id=jid(ev), message="Evidence uploaded.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def _can_view_owner(c: Caller, ev: Evidence) -> bool {
    if ev.owner_type == "SHIPMENT" {
        sh = get_shipment(ev.owner_id);
        return sh is not None and can_view_shipment(c, sh);
    }
    if ev.owner_type == "CLAIM" {
        cl = get_claim(ev.owner_id);
        return cl is not None and can_view_claim(c, cl);
    }
    if ev.owner_type == "QUALITY" {
        q = _quality_record(ev.owner_id);
        lot = get_lot(q.lot_id) if q is not None else None;
        if lot is None {
            return False;
        }
        return manages_plant(c, lot.plant_id) or dispatcher_covers_plant(c, lot.plant_id) or c.has_role(Role.ADMIN);
    }
    return False;
}

def:protect get_evidence_file(evidence_id: str) -> EvidenceFile {
    try {
        c = current_caller();
        ev = get_evidence(evidence_id);
        if ev is None or not _can_view_owner(c, ev) {
            raise not_found("Evidence");
        }
        blob = blob_of(ev);
        if blob is None {
            raise not_found("Evidence file");
        }
        return EvidenceFile(ok=True, filename=ev.filename, mime=ev.mime, data_b64=blob.data_b64);
    } except AppError as e {
        return EvidenceFile(ok=False, code=e.code, message=e.message);
    }
}
