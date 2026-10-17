# MineFlow AI

A role-based mineral ordering, dispatch and delivery platform for mining
plants and mineral buyers, built on **Jac / Jaseci**. Six operational
personas (Buyer, Store Manager, Dispatcher, Loader, Driver, Platform Admin)
each get their own authorized dashboard, and a genuine agentic **Dispatch
Planning Agent** / **Exception Recovery Agent** (real `by llm(tools=[...])`
tool-calling, with a labelled deterministic fallback when no LLM key is
configured) drives plant recommendations and exception recovery.

This is a working application: orders really reserve real stock and loading
slots, loaders and drivers really progress a shipment through checked
states, and every sensitive read/write is authorized server-side - never
only by what the UI happens to show.

## Quick start

Jac 0.37.25 runs only inside **WSL Ubuntu** on this machine. From a Windows
terminal (PowerShell or Git Bash with `MSYS_NO_PATHCONV=1` set):

```bash
wsl -d Ubuntu
cd /mnt/l/Gishani/AI-hackathon   # adjust to wherever this repo lives under /mnt
cp .env.example .env             # optional - sensible defaults work with no .env at all
export MINEFLOW_BUILD_DIR=/home/$USER/.mineflow-build   # avoids a bun-install hang on /mnt drives
jac check .                      # type-check the whole project
jac test                         # run the test suites (no API key needed - MockLLM)
jac run --dev main.jac           # start the dev server
```

Open `http://localhost:8000` (or whatever port `jac run` prints) from
Windows. Sign in from `/login` using one of the seeded demo personas below -
no password needed beyond what the page fills in for you.

A helper wrapper is convenient if you hit the same drvfs slowdown:

```bash
# ~/bin/mf
cd /mnt/l/Gishani/AI-hackathon && export MINEFLOW_BUILD_DIR=/home/$USER/.mineflow-build && exec "$@"
# usage: ~/bin/mf jac check .
```

## Demo sign-in (clearly labelled, not production auth)

The `/login` page's "Demo sign-in" tab lists seeded personas from a public
`demo_personas()` endpoint (disabled automatically when `MINEFLOW_DEMO_MODE`
is false). Clicking one signs up/logs in with a shared demo password and
binds that browser session to the seeded account via `claim_demo_persona`.
Primary personas you'll actually want to click through:

| Persona | Role | Notes |
|---|---|---|
| Nadeesha Perera | Buyer | Kelani Cement Works - the main order-to-delivery walkthrough |
| Kasun Bandara | Store Manager | Eppawala, Matale and Puttalam plants |
| Dilani Wickramasinghe | Dispatcher | Island-wide dispatch scope |
| Sunil Rathnayake | Loader | Puttalam Limestone Plant |
| Mahesh Gunawardena | Driver | Heavy-vehicle, based near Colombo |
| Amaya Rodrigo | Platform Admin | Users, orgs, invites, demo reset |

A handful of secondary personas (`buyer2`, `manager2`, `dispatcher2`,
`loader2`, `driver2`/`driver3`/`driver4`) exist to exercise
cross-tenant isolation and a genuinely free driver/truck for assignment.
Real (non-demo) accounts are provisioned by an admin-issued, single-use
invite code (`admin_create_invite` / `redeem_invite`), or - for the very
first administrator, before any admin exists - a `MINEFLOW_BOOTSTRAP_ADMIN_CODE`
secret set in `.env`.

## Architecture

**One app-owned operational graph.** A `MineFlowHub` node hangs off
`root.shared`. Every domain node/edge extends `DomainNode`/`DomainEdge`,
whose `__jac_access__` deliberately returns `AccessLevel.WRITE` - the Jac
runtime's own access control is *not* the policy layer here. **All real
authorization lives in `core/access.jac`**, invoked at the top of every
`def:protect` endpoint: role checks, organization/plant scope checks,
ownership checks. UI-side role gating (`shell/RoleLayout.jac` redirecting a
buyer away from `/dispatch`) is a UX convenience only, never the security
boundary - every endpoint re-checks role, ownership and scope itself,
independent of what the client sent.

**Validate-then-mutate.** Every state-changing endpoint fully validates
(raising typed `AppError`s with stable `code`s like `ACCESS_DENIED`,
`VALIDATION`, `CONFLICT`) before touching the graph, so a failed validation
never partially mutates state - the request's SERIALIZABLE transaction has
nothing to roll back.

**Atomic reservation.** `reservations/reserve.jac` re-reads lot availability
(measured − held reservations − quality-held) and slot status inside the
same transaction that creates the `Reservation` and holds the
`LoadingSlot`. Two buyers racing for the last tonnes of a lot cannot both
win - proven by `tests/workflow_tests.jac`'s "the last tonnes cannot be
reserved twice".

**Explicit, separated state machines** (`core/state_machines.jac`): delivery
progress (`ShipmentStatus`), connectivity (`ConnectivityStatus`, computed
purely from last-ping age - a stale signal never fails or completes a
delivery), claims (`ClaimStatus`), payments (`PaymentStatus`). A photo upload
alone never closes a delivery; completion needs either the buyer's in-app
acknowledgement or a valid handover PIN, plus the required evidence.

**Agentic workflow** (`planning/`). The Dispatch Planning Agent and
Exception Recovery Agent call real, read-only, traced tools
(`planning/tools.jac`) via `by llm(tools=[...])`; every tool call is logged
with its args/result/duration through a `RunRecorder`. When no LLM key is
configured (or the model prefix has no matching key), `planning/fallback.jac`
runs the *same* tools in a fixed order - the run is stored and visibly
labelled "Deterministic fallback", never presented as a genuine agent run.
Either way, `planning/validate.jac` independently re-validates every
proposed option against live state before anything is applied - an LLM
hallucinating a lot that belongs to a different plant gets caught and
rejected with a recorded reason, not silently trusted. See
`tests/agent_tests.jac` for this proven with `MockLLM` (no network, no key).

**Project layout.**
```
core/        kernel: enums, node/edge model, hub, config, access, state machines, geo, views
catalog/     minerals, grade specs, compatibility
inventory/   stock lots, spreadsheet import/export, availability
scheduling/  hourly loading-slot materialization, loader shifts
reservations/ atomic reserve/release/consume
orders/      buyer ordering, recommendations, confirm/cancel, acknowledge/report issue
planning/    agent tools, LLM agent, deterministic fallback, validation, orchestration
dispatch/    ops overview, queue, assignment approval, exception register + recovery
delivery/    driver workflow, location tracking/connectivity
loading/     loader workflow (check-in, verify, finish)
evidence/    photo/document uploads
claims/      quality/quantity/delivery claims
messaging/   per-shipment threads + notifications
payments/    settlement ledger (simulated)
admin/       users/orgs/plants/invites/demo reset
seed/        fictional Sri Lankan mineral industry scenario
identity/    session + demo persona / invite / bootstrap-admin binding
shell/       client dashboard shell, nav, status chips, map, state views (components/ui is vendor-managed; never hand-edited)
hooks/       reusable client fetch+state (useSession, usePoll)
pages/       file-based routes - pages/(auth)/<role>/... per persona
tests/       kernel, workflow, agent (MockLLM) and operations test suites
```

## Security model

- Every sensitive endpoint is `def:protect` (JWT required); the only public
  endpoints are `platform_status` and `demo_personas` (demo mode only, no
  secrets).
- Buyers only ever see their own orders/shipments/claims; store managers are
  restricted to their assigned `plant_ids`; dispatchers to their
  `dispatch_plant_ids`; drivers/loaders to their own assignments and
  eligible unclaimed jobs at their plant(s).
- Admin-only endpoints (`admin/store.jac`) require the `ADMIN` role and are
  never reachable by any other role, regardless of what the client requests.
- Handover PINs are random 6-digit codes shown only to the buyer; 5 failed
  driver attempts lock the shipment into an exception for dispatcher review.
- Dispatcher overrides (choosing a driver/truck/loader other than the
  recommendation) require a recorded reason (`OVERRIDE_REASON_REQUIRED`),
  kept in the audit trail.

## Honest labelling of simulated data

- **Maps/GPS**: Leaflet + OpenStreetMap tiles; routes are a simulated
  straight-line-times-road-factor estimate, never real traffic data. The
  driver app offers a "Simulated route" mode (interpolates along that
  estimated route) and a "Device GPS" mode (real `navigator.geolocation`),
  and both are labelled as such in the tracking view's `note` field. A stale
  position is shown as "last confirmed … ago", never redrawn as live.
- **Payments**: `payments/ledger.jac` is explicitly a simulated settlement
  ledger - no real money moves. Every page that shows an amount says so.
- **Seed data**: `seed/demo_data.jac` is a fictional Sri Lankan mineral
  industry scenario (rock phosphate, dolomite, limestone, ilmenite, silica
  sand) with made-up companies, plants, trucks and six pre-built order
  scenarios covering every shipment state. Demo "photo" evidence is a
  generated placeholder PNG, not a real photograph.
- **AI agent**: the active mode is always visible as a badge
  ("AI agent · anthropic/claude-sonnet-5" vs "Deterministic fallback …") in
  the dashboard header and on every plan/recovery card.

## Testing

```bash
jac check .      # type-check everything
jac test         # kernel, workflow (incl. the overselling race), agent (MockLLM), operations suites
```

No test requires a real LLM key - `MockLLM`/`MockToolCall` execute the
actual tool functions and record a real `conversation`, so the agent tests
prove genuine tool execution, scope enforcement, and rejection of invalid
LLM-proposed options, not just that a mock returned something.

## Jac percentage (AGENTS.md §1)

Counted with nonblank-line `grep -c` across every `*.jac` file, excluding
the jac-shadcn-managed `components/ui/` primitives, the generated
`lib/utils.jac`, and the `.jac/` build directory:

- Hand-written Jac (nonblank lines): **15,925**
- Hand-written non-Jac source (nonblank lines): **0** (no custom
  `.js`/`.ts`/`.py` application files exist in this project; `styles/global.css`
  is jac-shadcn-generated, not hand-written)
- **15,925 / 15,925 = 100% Jac**, well above the 80% requirement.

## Known limitations

- Leaflet tiles require internet access at runtime; offline, the map falls
  back to a blank tile grid (markers/route still render).
- The loading-slot grid is materialized 3 days ahead lazily; very
  far-future orders (>14 days, already rejected at order-creation time)
  would need an explicit extension.
- `jac browse` end-to-end screenshots were not captured in this submission
  pass; manual verification was done via the running dev server.
- Store-manager "Loading Schedule" is derived from reservation data (no
  separate store-manager-facing slot endpoint exists yet) rather than the
  dispatcher's richer bay/slot grid.
