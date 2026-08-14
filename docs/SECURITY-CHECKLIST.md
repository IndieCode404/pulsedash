# Security checklist — the HTML dashboard must not create vulnerabilities

A reviewable gate. Every item must pass before real instances are connected. Kept
out of steering on purpose (it's long) — read it when doing security work, not on
every request.

## Output encoding / XSS  (the top risk for this dashboard)
The dashboard renders data collected from monitored servers — **login names, host
names, program names, query text, database and table names, error messages**. All of
it is untrusted.
- [ ] Every value written into HTML goes through `esc()` (escapes `& < > "`).
- [ ] No `innerHTML =` (or template string assigned to `innerHTML`) built from
  collected data without `esc()` on each interpolated value.
- [ ] Table cells, tooltips (`title="..."`), and any status/label helper escape their
  input — including "safe-looking" fields like server roles and metric names.
- [ ] No `document.write`, `eval`, `new Function`, or `setTimeout(string)`.
- [ ] No inline `onclick`/`on*` attributes built from data. Use delegated event
  listeners keyed by a `data-` id, not a JSON blob interpolated into markup.
- [ ] Values never placed unescaped into a URL, `href`, or query string.

## Content Security Policy
- [ ] The API responses/pages send a CSP header, e.g.
  `default-src 'self'; script-src 'self'; style-src 'self'; object-src 'none';
  base-uri 'none'; frame-ancestors 'none'`.
- [ ] No third-party origins (the product is self-contained — scripts, styles, fonts,
  images are all local). If any inline script remains, move it to a `.js` file so CSP
  can forbid `unsafe-inline`.

## CSRF (state-changing API calls)
- [ ] POST/PUT/DELETE endpoints require the custom `X-DBADash` header (a cross-site
  "simple" request can't set it without a preflight we never approve).
- [ ] They reject a foreign `Origin`; same-origin requests pass.
- [ ] GET endpoints are read-only and side-effect free.

## SQL injection
- [ ] Every dynamic query is **parameterised** (`AddWithValue` / a builder). No value
  is string-concatenated into SQL — on the API side or in the collectors.
- [ ] Dynamic SQL, if any, is isolated and takes no untrusted input.

## Path traversal (static file server)
- [ ] The static handler resolves the full path and confirms it stays under the `www`
  root before serving; otherwise 404.
- [ ] Only expected content types are served.

## Transport & exposure
- [ ] The listener binds to **localhost only** — never `0.0.0.0`/a public interface.
- [ ] No built-in auth is assumed; if the dashboard is ever shared, it is fronted by a
  reverse proxy with authentication + TLS. Documented, not silently exposed.
- [ ] SQL connections: `TrustServerCertificate` is a conscious choice; on an untrusted
  segment, validate the cert instead.

## Secrets & data exposure
- [ ] No secret in code, committed config, logs, or a client response. `rpt.Servers`
  exposes `HasPassword` only, never the blob.
- [ ] Stored target passwords are DPAPI-encrypted (or an env var / integrated auth).
- [ ] 500 responses don't leak internal detail beyond what's needed to diagnose.
- [ ] `deploy/config/dbadash.json` stays git-ignored; only the example is committed.

## Least privilege
- [ ] The collector account has `VIEW SERVER STATE` + `db_datareader` on `msdb` on
  targets, `db_datawriter` on the central DB — **no sysadmin**.

## Dependencies / supply chain
- [ ] Production ships zero third-party runtime libraries (no CDN, no npm at runtime).
  Any dev-only tool is not in the shipped package.

## Verification
- [ ] A grep/read pass confirms no `innerHTML` without `esc`, no string-built SQL, no
  outbound URL in the product. Record the result in the PR/commit.
