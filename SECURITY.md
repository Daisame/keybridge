# Security

Keybridge deliberately uses a powerful mechanism (network ADB) to get at button
presses Android does not expose to apps. This page explains what you are
trusting, what the code does to limit the damage, and what it cannot fix.

**Status:** hobby project, built with AI assistance, reviewed in two automated
passes (security; efficiency and resilience). It has **not** been independently
audited. Treat it accordingly.

## What you are trusting

| You trust | Why it matters |
|---|---|
| **The TV box, with ADB open on your network.** | Network ADB lets an authorised client run a shell on the box: install and remove apps, take screenshots, inject input, read shared storage, reboot. Some inexpensive boxes ship with ADB authentication disabled, which gives that to anyone on the network. |
| **The add-on's ADB key.** | "Always allow" makes that key a permanent credential for the box. The key sits in the add-on's `/data/.android` and is included in Home Assistant backups. |
| **The add-on code, with a full-access Home Assistant token.** | Firing an event needs the `homeassistant_api` permission, which is the Supervisor's only option and is effectively full access to Core's API: call services, read all states, render templates. Anything that compromises the add-on compromises Home Assistant. |
| **Your local network.** | ADB over TCP is authenticated at connect time but **not encrypted**. |
| **The Home Assistant event bus.** | Key presses become ordinary events. Every integration, custom component, automation and administrator can see them, and anything holding an API token can fire a forged `adb_key` event. The recorder may store them. |

## The biggest design weakness: it reads every input device

`getevent` streams events from *all* input devices on the box. The add-on filters
to your configured keys, but it filters **after** the stream has crossed your
network in cleartext. If a Bluetooth keyboard is paired to the TV, a passive
listener on your network could see everything typed on it, passwords included.

We looked at filtering on the TV instead and decided against doing it by default
(see [docs/DESIGN.md](docs/DESIGN.md)): it adds fragile quoting and buffering
behaviour on devices we cannot test, for a risk that network separation handles
better. If this matters to you, isolate the TV (below).

## What the code does to limit risk

Checked in code review and exercised in tests with a fake `adb`:

- **No shell injection path.** Option values and device output are always quoted,
  nothing is `eval`'d, and key names are matched by exact lookup, not by a regex
  built from options.
- **Forged-event protection.** The event body is built with `jq`, and the device
  path reported by the TV is validated, so a misbehaving TV cannot add fields or
  fake a key that is not in your allow-list. (This was a real finding in review.)
- **Input validation.** `adb_host`, `event_type` and each key name are checked by
  the add-on schema and again when the script starts.
- **Token off the command line.** The Supervisor token is passed to `curl` on
  stdin, so it does not appear in a process listing, and it is never logged.
- **Private key storage.** The ADB key directory is created with mode `700`.
- **Minimal permissions.** No host network, no privileged mode, no ports, no
  Supervisor API; only `homeassistant_api`.
- **Bounded retries.** A reconnect delay that grows from 10 s to 2 minutes limits
  how often the TV is asked to show the "Allow USB debugging?" prompt.

## What it cannot fix

- Cleartext ADB on your network (see above).
- The meaning of "Always allow".
- The full-access token. There is no narrower scope for firing events today. A
  webhook instead of the token is possible but changes the event model; we have
  not done it.
- A compromised Home Assistant instance or add-on host.
- **Supply chain.** The add-on is built locally from this repository on an
  **unpinned** Home Assistant base image (`:latest`) with unpinned `apk`
  packages, and there is no prebuilt, signed image. If you want reproducible
  builds, pin the base image yourself.
- A hostile TV that floods events or sends a huge line without a newline. The
  TV has already been authorised, and we judged the cost of defending against it
  too high for this project.

## Hardening checklist

1. **Isolate the TV.** Put it on a separate VLAN or IoT network, or firewall port
   5555 so only the Home Assistant host can reach it. **Never forward 5555
   through your router.**
2. **Reserve the TV's IP address** so the add-on keeps talking to the right
   device.
3. **Keep the `keys` list short.** Volume, mute and power are fine. **Do not add
   letters, digits or anything that is typed text**; the events would be a
   keylogger in your Home Assistant logs, event bus and (possibly) database.
4. **Exclude the events from the recorder** if you do not want them stored:
   `recorder: exclude: event_types: [adb_key]`.
5. **Protect your backups.** They contain the ADB key. Encrypt them and store
   them somewhere only you can read.
6. **Know how to revoke.** On the TV: Developer options -> "Revoke USB debugging
   authorizations". To rotate the key: stop the add-on, delete
   `/data/.android`, start it, and accept the new prompt.
7. **Turn network debugging off** on the TV if you stop using Keybridge.
8. **Cap repeating automations.** A lost key-up must not leave a volume ramp
   running. This is an equipment and hearing-safety issue, not only a security
   one.

## For people borrowing or adapting this code

- Do **not** reuse the "Always allow" pattern for anything that handles typed
  input, credentials or devices you do not fully control.
- Do **not** widen the key filter casually. Every extra key is another thing
  visible on the event bus.
- Remember that Home Assistant events are **not private** and not authenticated:
  an automation that acts on `adb_key` trusts everything that can fire it.
- Keep input validation when you change option handling. The forged-event bug
  came from trusting one field of the device's output.
- If you package this as a prebuilt image, pin the base image by digest and
  consider a CI build with provenance.
- Do not describe this as secure. It is "as safe as network ADB plus a trusted
  add-on", which is a trade-off, not a guarantee.

## Reporting a problem

Please report vulnerabilities privately using GitHub's "Report a vulnerability"
button on the repository's **Security** tab (private vulnerability reporting must
be enabled by the maintainer). If that is not available, open an issue that says
you have a security report and **leave out exploit details**, and the maintainer
will arrange a private channel.

This is a hobby project, so response times are best effort.
