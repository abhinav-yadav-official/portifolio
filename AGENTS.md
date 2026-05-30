# AGENTS.md

## Project Purpose

This is the static personal website for `abhiyadav.in`, hosted from the canonical GitHub repo `abhinav-yadav-official/portifolio` (the misspelling is intentional). The site is a single-page portfolio with SEO/social metadata, a Three.js galaxy backdrop, project and experience sections, custom error pages, and a linked resume PDF.

There is no application build step. Files ship largely as authored.

## Directory Structure

- `index.html` - main single-page site; contains the HTML, CSS, and browser JavaScript.
- `assets/icons/` - vendored local technology icons used by the homepage.
- `assets/vendor/` - vendored Three.js modules loaded by `index.html`.
- `scripts/check_homepage.py` - local validation script for homepage content, SEO, interaction, asset, and deploy invariants.
- `scripts/deploy_homepage.sh` - SSH/rsync/nginx/certbot deploy script for the VPS.
- `.github/workflows/deploy.yml` - GitHub Actions deployment workflow for pushes to `main` and manual runs.
- `docs/` - screenshot and design/planning notes.
- `403.html`, `404.html`, `50x.html` - custom nginx error pages.
- `robots.txt`, `sitemap.xml`, `ads.txt`, favicons, `og-image.png`, `resume.pdf` - static public assets.

## Build, Run, Test

- List Taskfile commands: `task --list`
- Validate locally: `task test`
  - Runs `python3 scripts/check_homepage.py`
  - Runs `bash -n scripts/deploy_homepage.sh`
- Validate live legacy redirects too: `task test:live`
- Open locally: open `index.html` directly in a browser; no dev server is required.
- Deploy manually: `task deploy -- abhiyadav.in`

Required local tools for deployment are `ssh`, `rsync`, and `python3`. The deploy script can configure nginx and TLS on the remote host depending on environment flags.

## Key Conventions

- Keep the site static and dependency-light. Do not introduce a bundler or package manager unless there is a clear need.
- Keep Three.js vendored under `assets/vendor/`; `index.html` should load the local module, not a CDN.
- Keep icons local under `assets/icons/`.
- Preserve public routes expected by nginx and tests:
  - `/resume` serves `resume.pdf`.
  - `/linkedin` and `/github` redirect from nginx.
  - `/leetdrill/` proxies to the LeetDrill service.
- Preserve `/var/www/html/shared/` during deploys; the deploy script intentionally uses `--exclude=shared/`.
- Keep contact email obfuscated in the homepage with `data-email-local` and `data-email-domain`; do not add plaintext email addresses.
- Respect reduced-motion behavior for typing/reveal/galaxy animation changes.
- Keep mobile text overflow protections and responsive breakpoints intact.
- The homepage validation script is the source of truth for required content and behavior. Update it deliberately when changing site invariants.

## Gotchas

- `scripts/check_homepage.py` checks many exact strings in `index.html`, deploy config, and the GitHub Actions workflow. Small wording or structural edits can break `task test`.
- The SEO title, meta description, headings, project names, resume metrics, and archive repo links are intentionally asserted.
- Galaxy behavior is tightly tested: fixed full-page backdrop, local Three.js, configured zoom levels, Sgr A* anchor, click-to-zoom, keyboard spin, no old grid/line/ring effects, and no decorative CSS radial backgrounds.
- Deploy can run first-time remote setup only if passwordless sudo is available. In GitHub Actions, system setup is disabled and nginx setup is enabled.
- `ENABLE_TLS=auto` expects an existing certificate or `LETSENCRYPT_EMAIL` when certbot must create one.
- `.github/workflows/deploy.yml` defaults SSH port to `2022` and uses `DEPLOY_SSH_KEY`; keep these aligned with VPS settings.
