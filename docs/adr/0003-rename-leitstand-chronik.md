# ADR-0003: Rename leitstand → chronik, introduce leitstand UI
Status: Proposed
Date: 2025-11-14

## Kontext
- The existing `leitstand` repository serves as the event store, handling ingest, persistence, and auditing.
- A planned monitoring UI is intended to be the actual control center, providing dashboards and system overviews.
- This creates a semantic conflict: the "control center" (`Leitstand`) is functionally a chronicle/event store, while the real control center is yet to be built.

## Entscheidung
- To resolve this ambiguity and create clear responsibilities, the repositories will be restructured:
  1.  **Backend repository will be renamed**: `leitstand` → `chronik`. This aligns the name with its function as an event store and historical record.
  2.  **A new UI repository will be created**: A new repository named `leitstand` will be created to house the future UI/dashboard, which will act as the central control room.

- This ADR documents the decision to perform this renaming and restructuring.

## Konsequenzen
- **Clarity**: The roles of the backend and frontend components become semantically clear. `chronik` is the memory, `leitstand` is the cockpit.
- **Code Changes**: All references to the `leitstand` backend across all `heimgewebe` repositories must be updated to `chronik`. This includes code, documentation, CI/CD workflows, and `.ai-context.yml` files.
- **New Repository**: A new, initially minimal, `leitstand` repository for the UI will be created.
- **Temporary Inconsistency**: During the transition, there might be a brief period where documentation and code are out of sync. This change should be executed in a short timeframe to minimize disruption.

## Implementierungsnotizen
- The renaming will be executed in phases as outlined in the user's request.
- Phase 0: Discovery of all "leitstand" references.
- Phase 1: Documentation and conceptual fixation (this ADR).
- Phase 2: Technical renaming of the backend repository and all its references.
- Phase 3: Creation of the new `leitstand` UI repository.
- Phase 4: Review and mitigation of potential issues like broken links.

## Alternativen
- **Keep the names as they are**: This was rejected as it perpetuates the semantic confusion between the event store and the UI.
- **Choose different names**: `eventstore` was considered for the backend, but `chronik` was chosen for its better fit with the project's German-language context.
