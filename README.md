# Keybridge

**Use the buttons on your Android TV remote to trigger anything in Home Assistant, including buttons that Android hides from apps.**

Keybridge is a Home Assistant add-on. It connects to an Android TV / Google TV
box over network ADB, listens for button presses on the box's remote (volume,
mute, power, anything the remote sends), and fires a Home Assistant event for
every press and release. An automation can then do whatever you like: change a
soundbar's volume through an IR blaster, dim the lights, run a script.

> **Read this before you install:** Keybridge needs network ADB on your TV, which
> is a powerful, unencrypted back door, and the add-on holds a full-access Home
> Assistant token. It is a hobby project, built with AI assistance and not
> independently audited. See [Security](#security) and [SECURITY.md](SECURITY.md).

## Why it exists

Many streaming boxes (the Onn 4K Pro is the one this was built on) send the
remote's **volume buttons straight to the HDMI-CEC volume handler**, which tries
to control the TV's volume. If your TV or soundbar ignores that, the buttons do
nothing, and apps that normally remap buttons (Button Mapper and similar) never
see them either.

The Linux kernel underneath Android still reports every button press, so
Keybridge reads those raw events over ADB instead. You also get real
**key down** and **key up** events, which is what makes smooth hold-to-repeat
volume possible.

## How it works

```
 Remote ──Bluetooth──▶ Android TV box ──ADB over your LAN──▶ Keybridge add-on
                                                                   │
                                           Home Assistant event: adb_key {key, state}
                                                                   │
                                      your automation ──▶ IR blaster, lights, anything
```

## Quick start

You need: Home Assistant OS or Supervised, an Android TV / Google TV box on your
network, and something for the automation to control.

1. **On the TV box:** turn on Developer options, then network debugging so it
   listens on port 5555. Give the box a fixed IP address (a DHCP reservation).
2. **In Home Assistant:** Settings -> Add-ons -> Add-on Store -> menu ->
   Repositories, add `https://github.com/Daisame/keybridge`, then install
   **Keybridge**.
3. **Configure:** set `adb_host` to the box's IP address, then start the add-on.
4. **On the TV:** an "Allow USB debugging?" prompt appears once. Read
   [Security](#security), then tick "Always allow" and accept. (If the TV is on
   its screensaver the prompt may not show; wake it first.)
5. **Check it works:** open Developer Tools -> Events, listen for `adb_key`, and
   press a button on the remote. You should see `down` and `up` events.
6. **Build an automation** from [`examples/hold_to_repeat.yaml`](examples/hold_to_repeat.yaml).

More detail and all options are in [`adb_key_listener/DOCS.md`](adb_key_listener/DOCS.md).

**Setting this up with an AI agent?** Point it at [`AGENTS.md`](AGENTS.md).

## Example: remote volume buttons control a soundbar

The example in `examples/` makes the TV remote's volume up, volume down and mute
buttons drive a soundbar through a Broadlink IR blaster, with hold-to-repeat
(hold a button and the volume ramps, release and it stops). The repeat runs in a
small script that the key-up event cancels, which is more reliable than looping
inside an automation (see [docs/DESIGN.md](docs/DESIGN.md) for why).

## When you should not use Keybridge

- **If an accessibility remapper already sees your buttons** (Button Mapper, Key
  Mapper, and so on), use that. It is simpler and needs no network ADB.
- **If you only need to send commands *to* the TV**, use Home Assistant's built-in
  Android TV Remote or Android Debug Bridge integrations. They do not report
  button presses coming *from* the remote, which is the gap Keybridge fills.
- **If you cannot accept network ADB on your LAN**, do not use it.

## Security

The short version (full details in [SECURITY.md](SECURITY.md)):

- **"Always allow" is a permanent credential.** Whoever holds the add-on's ADB
  key gets a shell on the TV box.
- **ADB over TCP is not encrypted**, and the add-on reads *every* input device on
  the box, including a Bluetooth keyboard if one is paired. Everything crosses
  your network in cleartext before Keybridge filters it.
- **The add-on holds a full-access Home Assistant API token.**
- **Key presses become events** that every integration, automation and
  administrator can see, and the recorder may store them.

Put the TV on a separate network, never forward port 5555 through your router,
keep the `keys` list short, and do not add keys that are typed text.

## Things to know

- **Tested only on an Onn 4K Pro** (Google TV) with Home Assistant OS 18.3 / Core
  2026.10. Other boxes may use different key names or send duplicate events.
- **The TV still reacts to the button.** Keybridge observes; it does not block
  the key. The Onn still sends its CEC volume command; it is just ignored.
- **IR power buttons that only toggle can get out of step.** If your soundbar has
  a single power-toggle code and no way to report its state, any automation that
  sends it is a guess. Decide what you want when the soundbar turns itself off.
- **Cap every repeating automation.** If a key-up event is ever lost, a volume
  ramp keeps going. The example caps it at about six seconds.
- **No queue.** If Home Assistant is down when you press a button, that press is
  lost.
- **Local build.** Home Assistant builds the add-on on your machine from the
  repository, using an unpinned base image. See [SECURITY.md](SECURITY.md).

## Borrowing this code

You are welcome to (it is MIT licensed), but know what you are copying:

- The **ADB trust model** (a persistent "Always allow" key) is the heart of the
  risk. Do not reuse it for anything that handles typed input, passwords, or
  devices you do not fully control.
- The shell script is small on purpose and has had two review passes, but it has
  **not been audited by a person who does security professionally**.
- The **event bus is not private**. Do not put anything sensitive in the events.
- If you adapt it to forward more keys, read the keylogger warning in
  [SECURITY.md](SECURITY.md) first.
- Read [docs/DESIGN.md](docs/DESIGN.md) before changing the repeat or reconnect
  logic. Several choices there fix real bugs we hit.

## Documentation

| File | What it is for |
|---|---|
| [`README.md`](README.md) | This overview. |
| [`adb_key_listener/DOCS.md`](adb_key_listener/DOCS.md) | Options, events and setup detail (also shown inside Home Assistant). |
| [`SECURITY.md`](SECURITY.md) | Threat model, hardening checklist, how to report a problem. |
| [`docs/DESIGN.md`](docs/DESIGN.md) | Why it works the way it does, including dead ends. |
| [`AGENTS.md`](AGENTS.md) | Step-by-step setup guide written for an AI agent. |
| [`examples/hold_to_repeat.yaml`](examples/hold_to_repeat.yaml) | Script and automation for hold-to-repeat volume. |

## Status

Early prototype, v0.2.0, used daily on one setup. Issues and pull requests are
welcome. This project was developed with AI assistance (Claude) and reviewed in
two automated passes (security, and efficiency/resilience); there has been no
independent audit.

## License

MIT. See [`LICENSE`](LICENSE).
