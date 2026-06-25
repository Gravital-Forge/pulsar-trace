# PulsarTrace (PT)

**Product code:** `PT` · **Erratum record opened:** 2026-06-24

PulsarTrace is a local-only macOS meeting-transcription app: it captures microphone and system audio
on the user's Mac and writes speaker-labelled, timestamped Markdown transcripts, with no audio or
data leaving the machine. This directory is the source of truth for the product's requirements, its
architecture, and the traceability between them.

## How this directory works

- `product/` is the living specification of the product as it currently ships: `requirements.md`
  (the active requirements), `architecture/` (the as-built components, including the public output
  contracts), and `traceability.md` (the append-only matrix linking every requirement to its origin
  and its implementation).
- `projects/` holds each initiative that proposes changes to the product. A project is open while
  its work is in progress and frozen once its changes are reconciled into `product/`. Each project
  carries a PRD, a decision log, and its epics.
- Identifiers for requirements, components, projects, epics, and decisions are derived per the
  Erratum framework.

## Scope

Erratum tracks the product's **specification and build** — what the product must do, what it is
built from, and how each requirement traces to the work that delivered it. Operational material
(release smoke-test checklists, runbooks, spike and verification reports, QA logs) is out of scope
and lives outside this directory. User-facing narrative (`README.md`, `CHANGELOG.md`) also lives
outside it.

## Conventions specific to this product

- **Architecture is a directory, not a single file.** `product/architecture/` holds an `index.md`
  component map plus per-area files, including `events-log.md` and `transcript-format.md`, which
  carry the normative specifications of the public output contracts. This is a deliberate extension
  of the single-file architecture document, warranted by several large external contracts.
- **Requirement numbering.** Product requirement IDs `PT-R1`–`PT-R86` carry the numbers used by the
  product's originating specification, so existing references resolve unchanged; `PT-R87` onward are
  derived as max-plus-one in the usual way.

## Adoption status

Adoption is complete: the Erratum layer is the single source of truth for the product's
requirements, architecture, and traceability, reconciled through project P5. The standalone
specification documents that predated this layer have been retired (their history remains in git),
in-source requirement and decision references use Erratum IDs (`// PT-R…`, `// PT-P…-D…`), and the
public output contracts are specified in `product/architecture/`, with the end-user `docs/` files
pointing to them.
