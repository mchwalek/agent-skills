---
name: iis-express
description: "Use when installing, running, or configuring IIS Express, or debugging its errors — e.g. applicationhost.config questions, custom domains/host headers, 503 responses with Server: Microsoft-HTTPAPI/2.0, 400 Invalid Hostname, bindingInformation syntax, netsh urlacl, appcmd, or Visual Studio/Rider regenerating/reverting IIS Express config"
---

# IIS Express

## Overview

Lightweight, self-contained, per-user IIS for local dev (wraps Hostable Web Core). No Windows Process Activation Service — **you** launch/terminate sites (IDE, CLI, or system tray). Most tasks don't need admin rights. [MS docs: IIS Express Overview]

## Install

- Ships with Visual Studio, or install standalone: IIS 10.0 Express MSI from the Microsoft Download Center. Requires .NET Framework 4.0+.
- Binaries: `C:\Program Files (x86)\IIS Express\iisexpress.exe` and `appcmd.exe` (also `C:\Program Files\IIS Express\` on some setups).

## Run from the command line

Two mutually exclusive modes — never combine `/config` with `/path`:

```
iisexpress [/config:config-file] [/site:site-name | /siteid:id] [/systray:bool] [/trace:level]
iisexpress /path:app-path [/port:port-number] [/clr:clr-version] [/systray:bool]
```

- `/config:file` — full path to `applicationhost.config`. Default: `%userprofile%\Documents\IISExpress\config\applicationhost.config`.
- `/site:name` — site to launch by `name` attribute (case-insensitive). Omit to launch the first `<site>` in the file.
- `/siteid:id` — launch by numeric `id` instead.
- `/path:dir /port:n /clr:v` — run a folder directly with no config file; defaults to port 8080, CLR v4.0.
- `/trace:info|warning|error` — print startup diagnostics to the console (essential for binding failures).
- Admin rights are only required to bind ports ≤ 1024.

```
iisexpress /config:c:\myconfig\applicationhost.config /site:Foo
iisexpress /path:c:\myapp\ /port:9090 /clr:v2.0
```
[MS docs: Running IIS Express from the Command Line]

## applicationhost.config format

Per-user/per-project XML, NOT the same file as full IIS's. Typical locations:
- Standalone default: `%userprofile%\Documents\IISExpress\config\applicationhost.config`
- Visual Studio project: `<solutionDir>\.vs\<solutionName>\config\applicationhost.config`
- JetBrains Rider project: `<solutionDir>\.idea\config\applicationhost.config`

Relevant skeleton (`<system.applicationHost><sites>`):

```xml
<site name="MySite" id="3">
  <application path="/" applicationPool="Clr4IntegratedAppPool">
    <virtualDirectory path="/" physicalPath="C:\path\to\app" />
  </application>
  <bindings>
    <binding protocol="http" bindingInformation="*:9090:localhost" />
  </bindings>
</site>
```

`bindingInformation` = `IP:port:hostheader`. `IP` is usually `*` (any local IP). `hostheader`:
- **empty** (`*:9090:`) = weak wildcard, matches any Host header for the site's **root** application.
- **a hostname** (`*:9090:myapp.local`) = strong binding, matches only that Host header.
- `sslFlags` on an `https` binding controls SNI / centralized cert store behavior. [MS docs: `<binding>` config reference]

A site can have **multiple `<application>` elements at different `path`s** (sub-applications, e.g. `path="/d"`) sharing one set of site-level bindings — but if they share the same physical folder/`web.config`, see the config-inheritance pitfall below before doing this.

## Configure with appcmd

Target the right file with `/apphostconfig:"<file>"` (else it defaults to the machine's own IIS config):

```
appcmd list site /apphostconfig:"<file>"
appcmd list app /apphostconfig:"<file>"
appcmd set site MySite "/+bindings.[protocol='http',bindingInformation='*:9090:myapp.local']" /apphostconfig:"<file>"
appcmd set site MySite "/-bindings.[protocol='http',bindingInformation='*:9090:myapp.local']" /apphostconfig:"<file>"
appcmd add app /site.name:MySite /path:/d /physicalPath:"C:\path" /apphostconfig:"<file>"
```

**appcmd cannot rename an application's `path`** — the path is the app's identifier. To remount an app at a different path, edit the `<application path="...">` attribute directly in the XML (safe once nothing else is regenerating the file — see below), or delete + re-add. [MS docs: appcmd samples on the `<binding>` reference page]

## Custom hostnames / non-localhost Host headers

To accept a request whose `Host` header isn't `localhost` (e.g. a reverse proxy forwarding `Host: myapp.local`):

1. Add the hostname to the hosts file if it doesn't resolve: `127.0.0.1 myapp.local` in `C:\Windows\System32\drivers\etc\hosts`.
2. Reserve the URL with http.sys (admin, one-time): `netsh http add urlacl url=http://myapp.local:9090/ user=Everyone`. One `http://*:9090/` reservation authorizes **every** hostname on that port — you don't need one urlacl per hostname if you already have the wildcard.
3. **Add** a binding for the hostname — do **not** replace the existing `localhost` binding. Replacing it does not survive Visual Studio/Rider restarts; keep both:
   ```xml
   <binding protocol="http" bindingInformation="*:9090:localhost" />
   <binding protocol="http" bindingInformation="*:9090:myapp.local" />
   ```
4. Restart `iisexpress.exe` so it re-reads the config and re-registers with http.sys.
[MS docs: Handling URL Binding Failures in IIS Express]

### Sub-application gotcha (empirical — not in MS docs, verified on IIS 10.0 Express)

If the app you need to reach lives at a **sub-application path** (e.g. `path="/d"`, not the site root `/`):
- A **weak wildcard** binding (`*:9090:`) only serves the sub-application for `localhost` (which IIS Express auto-registers). For any other Host header it returns a kernel-level 503, even though the URL group is registered — see Troubleshooting below.
- Fix: add a **strong** binding for that exact hostname (`*:9090:myapp.local`) — strong bindings serve sub-applications correctly, one binding per hostname you need.
- A site needs a **root (`/`) application** to start at all — a site whose *only* application is a sub-path (e.g. `/d`) fails to serve requests (500) even on localhost. If your real app must live at `/d`, add a second, empty application at `/` (any physical folder — an empty directory is enough, no `web.config` required) purely so the site has a root.

### Mounting the same physical app at two paths in one site (config-inheritance crash)

Sub-applications don't get an isolated config load. `<system.webServer>` collections
that are inheritable, unique-keyed collections (`<modules>`, `<handlers>`, etc. — and
the classic-pipeline `<system.web><httpModules>` equivalent) are inherited from every
ancestor application in the same site, then the child's own `web.config` is layered on
top. If the site root app (`/`) and a sub-application (e.g. `/d`) point at the **same
physical folder** (same `web.config`), the sub-app inherits an entry the root already
added, then tries to add the identical entry again from that same file:

```
HTTP Error 500.19 - Internal Server Error
Config Error: Cannot add duplicate collection entry of type 'add' with unique
              key attribute 'name' set to '<ModuleName>'
Error Code:   0x800700b7
Module:       IIS Web Core
Notification: BeginRequest
```

This happens even though HTTP.sys itself registers and routes both mounts correctly
(see the binding notes above) — it's a **config-loading** failure, not a
binding/routing one, and it breaks **every** URL under the site, not just the sub-app.

Root cause in the `web.config`: entries added with `<add name="X" .../>` and no
preceding `<remove name="X"/>`. A single, non-nested application loading that config
once is fine; a child app under it loading the same file is not.

Fixes, in order of how much you control the `web.config`:
- **You control it:** add `<remove name="X"/>` immediately before every `<add name="X" .../>`
  in the affected collections, so re-loading the same entries down an inheritance chain
  is idempotent. This is the only fix that lets one `applicationhost.config` mount the
  same app at both `/` and a sub-path.
- **You don't control it, or don't want to touch it:** don't nest the two mounts in one
  site/config. Use **two separate IIS Express processes/configs**, each mounting the app
  exactly once (root in one, sub-path in the other) — e.g. two `/config:` files, or two
  run configurations in Visual Studio/Rider. Neither app inherits from the other because
  they're different processes with independent config loads. Trade-off: they can't share
  a port at the same time (run one at a time, or put them on different ports).

## Troubleshooting quick reference

Diagnose by the `Server` response header — it tells you which layer answered:

| Symptom | `Server` header | Meaning | Fix |
|---|---|---|---|
| 503, empty body | `Microsoft-HTTPAPI/2.0` | http.sys has no registered URL group for this exact `IP:port:host` — request never reached IIS Express | Add a binding (see above); if it's a sub-app, use a **strong** binding, not a wildcard |
| 400 "Bad Request – Invalid Hostname" | `Microsoft-HTTPAPI/2.0` | Older IIS Express behavior for an unrecognized Host header | Same fix — add the binding + urlacl |
| 500, non-empty response | `Microsoft-IIS/10.0` | Request reached the IIS Express worker; error is in the app or app pool | Check app-level logs/exceptions; can also be a transient cold-start compile — retry |
| `500.19` config error, "Cannot add duplicate collection entry ... 'name'" | (config error page, not a normal response) | Same app mounted at two paths in one site, sharing a `web.config` with non-idempotent `<add>`s in an inheritable collection | Add `<remove>` before each `<add>`, or split into two separate configs/processes — see "Mounting the same physical app at two paths" |
| Connection refused | — | `iisexpress.exe` isn't running, or nothing listens on that port | Launch the site; check `Get-Process iisexpress` |

Inspection commands:
```
netsh http show servicestate view=requestq   # registered URL groups per port, and which are being served
netsh http show urlacl url=http://*:9090/    # confirm the reservation exists
appcmd list app /apphostconfig:"<file>"      # list applications and their paths
```

First-hit compilation of a large app can take 60–90s and may 500 while warming up — retry before assuming a config problem.

## Visual Studio / Rider regenerating your config

Both IDEs manage `applicationhost.config` for a web project and can **regenerate it from project settings on every build**, silently reverting manual XML edits (bindings, application paths, etc.). Neither the project file's IIS URL setting nor `TRACK_IIS_URL`-style run-config flags control this — the regeneration is a separate switch.

**Rider fix (verified):** uncheck **"Generate applicationhost.config"** for the web project — in the project's Properties → Web tab, or in the IIS Express run configuration's edit dialog. This persists to `<project>.DotSettings` as the key `SkipGenerateApplicationHostConfig = True`, which is a normal, committable ReSharper/Rider settings file (shareable with a team, same category as `<solution>.sln.DotSettings`) — so the toggle can be checked into source control and applied for every developer automatically. Once unchecked, Rider stops touching the file and manual/scripted edits (including appcmd calls) persist across builds.

**Visual Studio:** does not regenerate on every build the way Rider does, but if a config reset is ever observed, re-apply the same fix (bindings + application paths) via a script (e.g. `appcmd` calls) rather than assuming a one-time manual edit will stick long-term.

Note: `launchSettings.json` / `iisSettings.iisExpress.applicationUrl` only applies to modern SDK-style projects that use the `IISExpress` launch profile — it has no effect on classic ASP.NET Framework web projects that drive IIS Express straight from `applicationhost.config`; don't reach for it there.
