# Suggested additions

Ranked by value per unit of effort. Nothing here is committed work — it's the list of things that came up while building this, with the reasoning for and against each, so a decision can be made rather than a default taken.

---

## Tier 1 — clear value, small effort

### 1. A `verify` command: the full release gate in one call

Chain what a release candidate actually has to survive:

```
xf verify Vendor/AddonId
  → php -l across every PHP file in the add-on
  → uninstall, then install from a clean slate
  → xf errors must be empty
  → board returns HTTP 200
  → each ACP options page for the add-on renders without a debug error
  → uninstall again, confirming teardown is clean
```

Every piece already exists as a separate command; this composes them and returns one exit code. It is the single highest-value addition, because it converts "I think it's fine" into a check that can gate a tag. Suitable for CI.

### 2. Database snapshot / restore

```
xf snapshot [name]      # mariadb-dump into snapshots/
xf restore  <name>
```

Testing an upgrade path (`1.0.7 → 1.0.8`) currently means a full `reset` and re-install to get back to the "before" state. A snapshot makes it seconds, which changes how often upgrade paths get tested at all — right now the honest answer for most add-ons is "rarely".

### 3. Multi-version matrix

Run the same add-on against XenForo 2.2 and 2.3, or PHP 8.2/8.3/8.4/8.5, without hand-editing `.env`:

```
xf use xf22        # a named profile: different webroot, DB name, port
xf use xf23
```

Compatibility claims in `addon.json` (`"require": {"XF": [2030000, ...]}`) are usually asserted, not tested. The `COMPOSE_PREFIX` and `HTTP_PORT` variables already make parallel stacks possible; this just wraps them in a profile.

### 4. Seed data

A command that creates forums, threads with known content, and users at known dates. Testing search, permissions or anything time-based against an empty board proves nothing — the Elasticsearch measurements in [docs/elasticsearch-xfes.md](docs/elasticsearch-xfes.md) required exactly this and it was done by hand.

Careful about scope: enough to be useful, not a fixture framework.

---

## Tier 2 — worth doing, more effort or narrower audience

### 5. GitHub Actions workflow

*Partly done in v1.1.0:* a lint workflow (shellcheck, PSScriptAnalyzer, hadolint, compose validation and a loopback-binding check) runs on every push and pull request. What remains is the part below.

A reusable workflow that stands the stack up on `ubuntu-latest`, installs the add-on and runs `verify`. The main obstacle is XenForo licensing: CI needs the source, which can't be committed. Practical route is a repository secret holding a URL to a private artifact, documented but necessarily left to the user.

### 6. Redis / Valkey cache backend

XenForo supports a cache backend, and production boards commonly run one. Not shipped by default on purpose: a dev environment without it surfaces cache-invalidation bugs that a cached environment would hide. Worth adding as an **opt-in profile** (`--profile cache`) for people specifically debugging cache behaviour.

### 7. Kibana or a lighter ES browser, under a profile

`xf es` covers most needs, but exploring an index interactively is genuinely easier in a UI. Must be added as a **service on the compose network** publishing only its own port, loopback-bound — never by publishing Elasticsearch's port. The correct pattern is already shown in [docs/SECURITY.md](docs/SECURITY.md).

### 8. HTTPS via a local CA

Some behaviour only appears under HTTPS — secure cookies, mixed-content warnings, OAuth callbacks for connected accounts. `mkcert` plus a Caddy or nginx front end handles it. Deliberately not default: a self-signed cert adds friction to every `curl`, every browser session and every agent interaction.

### 9. `xf logs --json` / structured diagnostics

`doctor` prints for humans. A `--json` flag would make it directly consumable by CI and by agents without text parsing. Cheap; the value depends entirely on whether anyone builds automation on top.

---

## Tier 3 — considered and rejected, or genuinely uncertain

### 10. Bundling XenForo source

**Rejected, permanently.** Commercial licensed software. Not distributable, not negotiable. The `XF_SOURCE` indirection exists precisely so this repo never has to hold it.

### 11. A production-shaped image

Tempting — "same image everywhere" is a good instinct. But the settings are opposite at almost every point (`display_errors`, `opcache.validate_timestamps`, debug mode, Xdebug, ES security), and an image that tries to be both is bad at both. If it's wanted, it should be a **separate** Dockerfile with its own documentation, not a flag on this one.

### 12. Kubernetes manifests

Someone will ask. For a single-developer local environment, Compose is the right tool and k8s is strictly more moving parts. If the goal is production deployment, that's a different repository with different security requirements — nothing in here is production-ready by design.

### 13. Auto-updating pinned image versions

Renovate or Dependabot could bump `mariadb:11.4` and `elasticsearch:8.19.25` automatically. Attractive, but an unattended Elasticsearch major bump can silently break XFES compatibility (it requires 7.2+ and treats OpenSearch as 7.10.2 regardless of its real version). Better as a **scheduled reminder to review**, not an auto-merge.

**Done in v1.1.0, in the review-only form.** A scheduled workflow opens a pin-review issue on the 1st of each month listing every pinned version, with a checklist; a person decides. Dependabot covers only the GitHub Actions pins: the image versions live in `.env` variables and Dockerfile `ARG`s, which it cannot read.

### 14. Windows containers

No. XenForo on Windows containers is not a configuration anyone runs in production, and the Linux container path through WSL2 already works well.

---

## Documentation gaps worth filling

- **A migration note for people already running a hand-rolled stack** — what to change, what to keep.
- **A worked example of the whole add-on release cycle** using this stack, from first `setup` to tagged release. The pieces are scattered across the docs; one narrative would tie them together.
- **Recorded terminal output for `doctor`** on a healthy stack, so people know what "good" looks like.
- **The XFES measurement methodology** in reproducible form. The numbers in [docs/elasticsearch-xfes.md](docs/elasticsearch-xfes.md) are real measurements from a specific experiment; publishing the seeding script would let others verify and extend them rather than take them on trust.

---

## Contributions

Issues and pull requests welcome, particularly:

- **Platform reports.** The Linux and macOS paths are written from documented behaviour and general experience; the Windows path is the one with the most hours behind it. Corrections from people running the other two in anger are the most useful thing this repo could receive.
- **Runtime coverage.** Podman, Colima and OrbStack are documented but lightly tested.
- **Anything in [docs/SECURITY.md](docs/SECURITY.md) that is wrong or out of date.** That document is the reason this repo exists in public form; errors in it matter more than errors anywhere else.
