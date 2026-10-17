"""Seeded DEMO personas. Public demo credentials - never production accounts.

All organizations and people here are fictional.
"""

import from core.enums { Role }

obj PersonaDef {
    has key: str,
        email: str,
        display_name: str,
        role: Role,
        org_code: str,
        blurb: str,
        primary: bool = True,
        login: bool = True,
        plant_codes: list[str] = [],
        dispatch_plant_codes: list[str] = [],
        license_class: str = "",
        home_lat: float = 0.0,
        home_lng: float = 0.0,
        shift_start_hour: int = 6,
        shift_end_hour: int = 18;
}

glob ALL_PLANTS: list[str] = ["EPW", "MDQ", "PLP", "PMS", "NSP"];

glob PERSONAS: list[PersonaDef] = [
    PersonaDef(key="buyer", email="nadeesha.perera@example.com", display_name="Nadeesha Perera", role=Role.BUYER, org_code="KCW", blurb="Procurement lead at Kelani Cement Works. Orders limestone, dolomite and silica."),
    PersonaDef(key="manager", email="kasun.bandara@example.com", display_name="Kasun Bandara", role=Role.STORE_MANAGER, org_code="SRM", blurb="Store manager for Serendib Minerals' Eppawala, Matale and Puttalam plants.", plant_codes=["EPW", "MDQ", "PLP"]),
    PersonaDef(key="dispatcher", email="dilani.w@example.com", display_name="Dilani Wickramasinghe", role=Role.DISPATCHER, org_code="MHN", blurb="Island-wide dispatcher at MineFlow Haulage Network.", dispatch_plant_codes=ALL_PLANTS),
    PersonaDef(key="loader", email="sunil.rathnayake@example.com", display_name="Sunil Rathnayake", role=Role.LOADER, org_code="SRM", blurb="Loader operator at Puttalam Limestone Plant.", plant_codes=["PLP"], shift_start_hour=6, shift_end_hour=20),
    PersonaDef(key="driver", email="mahesh.g@example.com", display_name="Mahesh Gunawardena", role=Role.DRIVER, org_code="MHN", blurb="Heavy-vehicle driver based near Colombo.", license_class="HEAVY", home_lat=6.95, home_lng=79.92),
    PersonaDef(key="admin", email="amaya.rodrigo@example.com", display_name="Amaya Rodrigo", role=Role.ADMIN, org_code="PLAT", blurb="Platform administrator: users, roles, organizations, demo reset."),
    PersonaDef(key="buyer2", email="ruwan.jayasinghe@example.com", display_name="Ruwan Jayasinghe", role=Role.BUYER, org_code="UAF", blurb="Buyer at Uva Agro Fertilizers (rock phosphate, dolomite).", primary=False),
    PersonaDef(key="manager2", email="ishara.fernando@example.com", display_name="Ishara Fernando", role=Role.STORE_MANAGER, org_code="CSL", blurb="Store manager for Coastline Sands' Pulmoddai and Nattandiya plants.", primary=False, plant_codes=["PMS", "NSP"]),
    PersonaDef(key="dispatcher2", email="tharindu.silva@example.com", display_name="Tharindu Silva", role=Role.DISPATCHER, org_code="MHN", blurb="Eastern desk dispatcher - scope limited to Pulmoddai.", primary=False, dispatch_plant_codes=["PMS"]),
    PersonaDef(key="loader2", email="chaminda.kumara@example.com", display_name="Chaminda Kumara", role=Role.LOADER, org_code="SRM", blurb="Loader at Eppawala Rock Phosphate Works (morning shift).", primary=False, plant_codes=["EPW"], shift_start_hour=6, shift_end_hour=14),
    PersonaDef(key="driver2", email="pradeep.s@example.com", display_name="Pradeep Senanayake", role=Role.DRIVER, org_code="MHN", blurb="Driver based in Kurunegala.", primary=False, license_class="HEAVY", home_lat=7.48, home_lng=80.36),
    PersonaDef(key="driver3", email="lahiru.w@example.com", display_name="Lahiru Wijesinghe", role=Role.DRIVER, org_code="MHN", blurb="Driver based in Anuradhapura.", primary=False, license_class="HEAVY", home_lat=8.31, home_lng=80.40),
    PersonaDef(key="staff-loader-epw2", email="asanka.d@example.com", display_name="Asanka Dissanayake", role=Role.LOADER, org_code="SRM", blurb="Eppawala loader (evening shift).", primary=False, login=False, plant_codes=["EPW"], shift_start_hour=12, shift_end_hour=20),
    PersonaDef(key="staff-loader-mdq", email="roshan.alwis@example.com", display_name="Roshan Alwis", role=Role.LOADER, org_code="SRM", blurb="Matale loader.", primary=False, login=False, plant_codes=["MDQ"]),
    PersonaDef(key="staff-loader-pms", email="priyantha.silva@example.com", display_name="Priyantha Silva", role=Role.LOADER, org_code="CSL", blurb="Pulmoddai loader.", primary=False, login=False, plant_codes=["PMS"]),
    PersonaDef(key="staff-loader-nsp", email="dinesh.perera@example.com", display_name="Dinesh Perera", role=Role.LOADER, org_code="CSL", blurb="Nattandiya loader.", primary=False, login=False, plant_codes=["NSP"]),
    PersonaDef(key="driver4", email="nuwan.herath@example.com", display_name="Nuwan Herath", role=Role.DRIVER, org_code="MHN", blurb="Driver based in Puttalam - free for new jobs.", primary=False, license_class="HEAVY", home_lat=8.03, home_lng=79.84)
];

def persona_by_key(key: str) -> PersonaDef | None {
    for p in PERSONAS {
        if p.key == key {
            return p;
        }
    }
    return None;
}
