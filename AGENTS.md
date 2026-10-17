# AGENTS.md — MineFlow AI

## Mission

Build **MineFlow AI**, a role-based mineral ordering, dispatch, and delivery platform for mining plants and mineral buyers. This is a working application, not just a dashboard mockup.

Use the supplied Figma design as the visual and interaction reference:

https://www.figma.com/design/sufC8X0NS7Oza1PWCC5Dth/Xception_Designathon?m=auto&t=bvnsm06Z8p8YTOfd-6

Adapt the online-delivery application design to industrial mineral delivery. Preserve its useful layout patterns, navigation, visual hierarchy, cards, forms, maps, status indicators, and interaction patterns where appropriate, but replace consumer food/order concepts with mining-specific workflows and terminology. If the Figma file cannot be accessed from the current environment, inspect any design assets available in the repository and continue with a consistent, polished design; do not claim to have inspected inaccessible screens.

## 1. Mandatory technology constraints

- At least **80% of first-party, hand-written application source-code lines must be Jac (`.jac`)**. Measure this using nonblank source lines; exclude generated code, third-party code, dependencies, lockfiles, and non-code configuration. Report the numerator, denominator, and percentage.
- Use Jac/Jaseci as the primary application platform: Jac language features, nodes/edges, walkers, and native Jac LLM/tool-calling capabilities where supported by the installed version.
- Implement the UI, domain logic, workflow orchestration, data models, and application services primarily in Jac.
- Use the connected Jac MCP tools to consult official documentation, examples, supported syntax, and compiler feedback.
- Do not build a separate React/TypeScript or Python/FastAPI application and merely wrap it in Jac. Add non-Jac code only where a necessary capability is not available in the supported Jac stack, and keep it minimal.
- Do not invent Jac syntax. Verify features against the installed version and documentation before using them.
- Inspect the workspace and `git status` first. Initialize Git only if the project is not already a repository; preserve existing work.

## 2. Product and user roles

Every person signs in to an account associated with a role and, where applicable, an organization. The interface and all server-side operations must be role-aware. Each role sees only the screens, orders, data, and actions relevant and authorized for that role.

Implement these five operational personas:

### A. Mineral Buyer / Client

The buyer can:
- Create an order with one or more mineral line items.
- Specify mineral type, required grade/quality specification, quantity in tonnes, delivery address/location, and required delivery deadline/window.
- See recommended plants ranked by grade compatibility, available stock, loading wait, estimated travel time/ETA, and estimated total cost.
- Review and confirm a proposed order after the system validates stock and a loading slot.
- View order status and the delivery timeline.
- Track the assigned truck on a map when live location is available.
- See the last confirmed location and timestamp if the driver loses connectivity; never present stale coordinates as live.
- Contact the driver through in-app communication or an authorized contact action.
- Confirm delivery using a supported acknowledgement method.
- Report grade, quality, quantity, or delivery issues and follow the claim status.

Buyer dashboard focus: **Create Order, My Orders, Plant Recommendations, Active Deliveries, Messages, Claims, Order Details**.

### B. Mining Plant Store Manager

The store manager belongs to a particular mining plant and can:
- View and update stock by mineral type, grade, stockpile/storage location, measured quantity, reserved quantity, and quality/verification status.
- Import inventory from a spreadsheet and export current inventory/report data.
- Review stock reservations and avoid overselling the same material.
- Record quality certificates or inspection evidence where available.
- Update expected production/replenishment and flag production or stocking delays.
- View loading schedules and notify the dispatcher of stock or readiness changes.

Store manager dashboard focus: **Plant Inventory, Stock Lots, Spreadsheet Import/Export, Quality Records, Reservations, Production/Restocking Schedule, Delays**.

A store manager may only access the plant(s) they are authorized to manage.

### C. Dispatcher

The dispatcher coordinates orders, plant readiness, loaders, vehicles, and drivers. They can:
- View the operational queue of orders and deliveries within their authorized organization/scope.
- Review the agent's ranked recommendations and supporting evidence.
- Assign or reassign a driver, suitable truck, and loader.
- Review loading-slot availability, expected waiting time, and delivery deadlines.
- Approve a feasible dispatch plan or override it with a recorded reason.
- Handle stock shortages, missed slots, driver cancellations, vehicle issues, and route/delivery exceptions.
- Receive alerts for late loading, delays, failed delivery, and buyer quality/quantity claims.
- Review the shipment evidence and route the claim to the relevant plant manager or responsible party.

Dispatcher dashboard focus: **Operations Overview, Order Queue, Dispatch Board, Loading Schedule, Drivers & Vehicles, Exceptions, Claims, Audit Trail**.

### D. Loader

The loader has a personal account and sees only their assigned or eligible loading jobs. They can:
- View the assigned plant/loading location, mineral type and grade, quantity, truck details, and scheduled slot.
- See the required arrival/presentation time.
- Check in at the loading place using a supported check-in action; use GPS/geofence only if genuinely implemented, otherwise label it as a manual/demo check-in.
- Notify the dispatcher of arrival, queue status, delays, and loading readiness.
- Confirm the correct material and truck before loading is authorized.
- Record loading start/end time and loaded quantity, and attach loading evidence or a load ticket.
- View their loading service fee and payment status.

Loader dashboard focus: **My Loading Jobs, Slot & Location, Check In, Loading Status, Load Ticket/Evidence, Payment Status**.

### E. Truck Driver

The driver has a personal account and sees only assigned or eligible jobs. They can:
- Review a delivery offer, material details, pickup point, destination, expected times, vehicle/payload requirements, and compensation details.
- Accept or reject an eligible offer.
- Navigate to the plant and check in for loading.
- Confirm loaded material and the load ticket before starting the delivery.
- Share location during an assigned journey and view the route/destination.
- Communicate with the buyer using the application's authorized communication feature.
- Upload unloading/proof-of-delivery photos and record handover.
- Request or capture buyer acknowledgment.
- Complete an assignment only when the required delivery steps and evidence are present.
- View their payout status.

Driver dashboard focus: **Available Offers, My Assignments, Pickup & Loading, Active Journey, Map & ETA, Messages, Proof of Delivery, Payouts**.

### F. Platform Administrator (minimum operational support role)

Provide a limited administrator role for managing users, organizations/plants, role assignments, and demo configuration. Do not make every account an administrator.

## 3. Authentication, authorization, and account isolation

Role-specific UI alone is not security. Enforce authorization on the server for every sensitive read and write.

- Users must only see the screens and actions permitted by their role.
- Enforce organization/tenant boundaries on orders, plant inventory, claims, assignments, messages, and location records.
- Store managers must be restricted to their assigned plants.
- Drivers and loaders must only access their own assignments and the information required to perform them.
- Buyers must only access their own orders and deliveries.
- Dispatchers must be restricted to their authorized operational scope.
- Never rely only on a hidden button or client-side route guard.
- Validate ownership, assignment, role, and state transitions on every relevant server-side operation.
- Do not expose credentials, API keys, internal secrets, or unrestricted data in the client.
- Include a practical seeded demo sign-in or role-switching flow only if clearly labelled as demo functionality. Do not describe a demo role selector as production authentication.

## 4. Core end-to-end delivery workflow

Build a coherent workflow across all five operational personas:

1. Buyer creates an order with mineral type, grade specification, quantity, destination, and delivery window.
2. The application checks eligible plants and recommends feasible options.
3. Buyer chooses an option; the plant store manager's stock and the loading slot are revalidated.
4. The system reserves stock and a loading slot atomically or through a safe reservation procedure. Do not confirm unavailable stock or a slot that was not actually reserved.
5. Dispatcher reviews and approves the feasible dispatch plan, assigns an eligible truck/driver and loader, and can override with a recorded reason.
6. Loader and driver check in at the plant; the material, grade, truck, and order are verified before loading.
7. Loader records loading events, quantity, and a load ticket/evidence.
8. Driver begins the journey and shares location when available.
9. Buyer sees live tracking or the last confirmed location/time during connectivity loss.
10. Driver uploads unloading evidence and requests handover acknowledgment.
11. Buyer confirms receipt or reports a mismatch.
12. A successful delivery moves to completion and settlement/reconciliation. A mismatch creates a linked claim visible to the dispatcher and relevant plant manager.

Represent delivery progress using explicit, validated states. Keep separate concepts separate:
- Delivery status (for example, scheduled, awaiting loading, loading, in transit, delivered, completed, exception).
- Connectivity status (live, weak, offline/stale).
- Quality/quantity claim status (open, under review, resolved, rejected).
- Payment/payout status (pending, approved, paid, failed).

Connectivity loss must not automatically mark a delivery as failed or completed. Uploading a photo alone must not silently close a delivery.

## 5. Mineral inventory, grade integrity, and scheduling rules

- Represent mineral types and grade/quality specifications explicitly.
- Track stock by plant and stock lot/stockpile, with quantity, grade, verification status, and reservations.
- Calculate available stock from physical stock minus reservations and any quality-held stock.
- Prevent concurrent orders from reserving the same stock.
- Do not mix grades unless the application explicitly models an approved blend that satisfies the buyer's specification.
- Maintain traceability from order line to source stock lot and shipment/load ticket.
- Spreadsheet imports must be validated, previewed, and auditable; invalid rows must not silently corrupt inventory.
- Loading schedules should consider loader availability, loading duration, scheduled truck arrivals, and existing reservations.
- Show loading estimates as estimates, not guaranteed queue-free service.
- Driver assignment must consider eligibility, availability, vehicle payload/suitability, destination, and time window—not just geographic proximity.

## 6. Agentic AI workflow — real Jac/Jaseci use

Implement a genuine agentic workflow using the Jac/Jaseci capabilities available in the installed version. Use native Jac LLM/tool-calling such as `by llm(tools=[...])` or the documented equivalent.

### Dispatch Planning Agent

The agent receives the order, uses Jac tools to collect evidence, evaluates available options, and recommends a feasible plant/dispatch plan. It should choose and invoke tools, inspect results, and continue the workflow as needed—not simply produce a generic explanation after deterministic code has already chosen the answer.

Potential Jac tools:
- `get_plant_inventory`
- `check_grade_compatibility`
- `estimate_loading_wait`
- `estimate_delivery_eta`
- `evaluate_plant_feasibility`
- `compare_dispatch_options`
- `reserve_stock_and_slot` (only after required checks and authorization)

### Exception Recovery Agent / workflow

When a plant becomes unavailable, a loading slot is lost, stock changes, or a driver cancels:
- Gather updated evidence using tools.
- Re-evaluate feasible alternatives.
- Explain what changed and why the alternative is preferred.
- Request dispatcher approval where the change has operational consequences.
- Report that no feasible alternative exists when appropriate.

Use Jac walkers and graph/domain state to coordinate the workflow and retain order/plan history. Multiple agents are optional; a small orchestrated workflow is preferred over several agents that only exchange static messages.

Log real tool invocations, inputs/outputs safe for display, evidence, decisions, recovery attempts, and failures. Never fabricate tool calls or claim a reservation succeeded if it failed.

### Deterministic safeguards around AI

The LLM may plan and recommend, but deterministic server-side code must enforce:
- Grade and stock feasibility.
- Reservation correctness and duplicate prevention.
- Role/tenant authorization.
- Allowed state transitions.
- Truck/quantity constraints.
- Required evidence before delivery completion.
- Payment ledger transitions.

Validate all LLM outputs before applying changes. Require dispatcher approval for dispatch confirmation or consequential reassignment unless a safe, explicitly defined policy authorizes the action.

If credentials are missing, keep the rest of the application runnable and clearly label any deterministic fallback. Do not misrepresent fallback behavior as a genuine LLM-driven agent run.

## 7. Design and UX requirements

Use the supplied Figma file as inspiration for a polished online-delivery-style experience, adapted for industrial mineral logistics. Reuse the general design language and useful patterns—not the food-delivery business model.

- Build a coherent design system: typography, spacing, colors, buttons, cards, form fields, tables, status chips, dialogs, empty states, loading states, and error states.
- Provide role-specific dashboards and navigation after sign-in.
- Use a consistent shell and shared components where appropriate, while showing each role only the relevant sections.
- Prioritize clear status, next action, deadlines, exceptions, and operational evidence over decorative graphics.
- Make the dispatcher view optimized for scanning many orders and exceptions.
- Make buyer tracking understandable and trust-building.
- Make loader/driver screens mobile-friendly, with large touch targets and minimal steps.
- Use a map only where it adds value. If map/routing/GPS services are simulated, label them as simulated.
- Do not invent real GPS signals, real payments, real messages, or real reservations. Clearly identify seeded/simulated demo data.
- Include meaningful empty/loading/error states, form validation, and confirmations for consequential actions.
- Do not leave important buttons decorative or nonfunctional.

## 8. Suggested Jac-first project organization

Follow the existing scaffold's conventions rather than forcing this exact tree, but keep modules logically separated. Possible domains:
- `auth` / `access_control`
- `catalog` / `grade_specifications`
- `inventory` / `stock_lots`
- `orders`
- `plant_recommendation`
- `loading_schedule`
- `dispatch`
- `driver_tracking`
- `delivery_evidence`
- `quality_claims`
- `messages_notifications`
- `payment_ledger`
- role-specific UI pages/components
- tests and seed data

Use Jac graph nodes/edges and walkers where they provide value for relationships and workflow traversal. Use the supported persistence mechanism appropriate for the scaffold. Do not add multiple databases or infrastructure services without a concrete need.

## 9. Development process

1. Inspect the existing project, Jac version, MCP tools, scaffold, and available Figma/design assets.
2. Check `git status`; initialize Git only if needed and preserve existing changes.
3. Verify Jac syntax and APIs against official docs and working examples.
4. Implement a small complete vertical slice first: sign-in/role context → buyer order → plant recommendation → dispatcher approval → loading/delivery status.
5. Add the store manager, loader, and driver flows and enforce access control across all server operations.
6. Implement the genuine agentic tool-calling workflow and observable exception recovery.
7. Test normal and failure paths. Fix compiler/runtime errors before optional enhancements.
8. Keep source code and README understandable. Add `.env.example` with variable names only, never real secrets.

## 10. Acceptance criteria

The application is acceptable only when:

1. It runs in the available local Jac development environment.
2. The UI is adapted to mineral delivery and reflects the supplied Figma design where accessible.
3. Buyer, store manager, dispatcher, loader, driver, and administrator have distinct authorized views/actions.
4. Server-side role, ownership, assignment, and organization checks protect sensitive operations.
5. A buyer can submit an order and receive a recommendation based on actual inventory/queue/ETA tool results.
6. Stock and loading slots cannot be over-reserved; infeasible orders are not confirmed.
7. Loader and driver can progress an assignment through the required operational steps.
8. Tracking distinguishes live position from last-known/offline location.
9. Delivery evidence and buyer acknowledgment are required according to the defined completion flow.
10. A quality/quantity issue creates a linked claim visible to the dispatcher and relevant plant manager.
11. Plant/slot failure triggers a real tool-using recovery workflow or a truthful no-feasible-option result.
12. Jac compiler checks and relevant functional tests pass, or remaining blockers are clearly documented.
13. At least 80% of first-party, hand-written application source lines are Jac; report the actual calculation.
14. Setup, configuration, seeded demo accounts/data, and limitations are documented.

Start by inspecting the existing workspace and available design assets, then build and test the application. Do not stop after producing a plan or mockup. Prioritize a working, coherent, role-secure mining delivery workflow implemented primarily in Jac/Jaseci.
