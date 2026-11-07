# AGENTS.md: setting up Keybridge for a user

This file is for an AI agent that has been pointed at this repository and asked to
set Keybridge up for a person. It is written to be followed step by step. Humans
should read [`README.md`](README.md) instead.

## What Keybridge is (read this first)

A Home Assistant add-on that connects to an Android TV / Google TV box over
**network ADB**, streams the box's raw input events (`getevent`), and fires a
Home Assistant **event** for each configured key press and release. An automation
then reacts, typically to send IR commands for a soundbar.

```yaml
project: keybridge
repository: https://github.com/Daisame/keybridge
addon_slug: adb_key_listener          # installed from a repo; local install slug is local_adb_key_listener
addon_version: 0.2.0
requires:
  home_assistant: "Home Assistant OS or Supervised (add-ons / apps)"
  architectures: [amd64, aarch64]
  tv_box: "Android TV / Google TV with network ADB (port 5555) enabled"
tested_on: "Onn 4K Pro (Google TV), Home Assistant OS 18.3, Core 2026.10, Supervisor 2026.10"
events:
  adb_key:        { key: "KEY_VOLUMEUP", state: "down|up|repeat", device: "/dev/input/eventN" }
  adb_key_status: { status: "connected|disconnected|unavailable" }   # transitions only
options:
  adb_host: "TV IP or hostname (required)"
  adb_port: 5555
  event_type: "adb_key"                # lowercase letters, digits, underscores
  keys: [KEY_VOLUMEUP, KEY_VOLUMEDOWN, KEY_MUTE]   # add KEY_POWER if wanted
  forward_repeat: false
```

Docs to consult as you go: [`adb_key_listener/DOCS.md`](adb_key_listener/DOCS.md)
(options, events), [`SECURITY.md`](SECURITY.md), [`docs/DESIGN.md`](docs/DESIGN.md),
[`examples/hold_to_repeat.yaml`](examples/hold_to_repeat.yaml).

## Rules of engagement

These are not optional. This project opens a powerful door on the user's network.

1. **Get informed consent before enabling or relying on network ADB.** Tell the
   user, in plain words: "Always allow" gives whoever holds the add-on's key a
   shell on the TV box; ADB over the network is unencrypted; the add-on holds a
   full-access Home Assistant token; and the whole input stream (including a
   paired Bluetooth keyboard) crosses the network before it is filtered. Point to
   [`SECURITY.md`](SECURITY.md). Proceed only after they agree.
2. **The user accepts the ADB prompt, not you.** Do not click "Allow" on the TV
   through `adb input`, a screenshot tool, or any other trick. Tell the user what
   to do and wait.
3. **Never show or log secrets.** Do not print Home Assistant tokens, the
   Supervisor token or ADB keys. Prefer a short-lived long-lived-access-token the
   user creates for this job and revokes afterwards.
4. **Do not expose port 5555** (no router forwarding, no public tunnel).
5. **One change at a time, verify each.** Confirm each step worked before the
   next. When copying files to a Home Assistant host, check checksums on both ends.
6. **Keep the key list short.** Volume, mute, power. Refuse to add letters,
   digits or anything typed (it would be a keylogger in HA's logs and database).
7. **Cap every repeating automation** (the example does). A lost key-up must not
   leave a volume ramp running.
8. **Ask before changing existing automations, scripts or integrations.** Create
   new ones with names that make clear what they are.

## Step 0: does the user actually need Keybridge?

Check before installing anything:

- If an accessibility remapper (Button Mapper, Key Mapper) already sees the
  button they want, recommend that instead.
- If they only want to *send* commands to the TV, recommend Home Assistant's
  Android TV Remote or Android Debug Bridge integrations.
- Keybridge fits when the button never reaches apps (commonly volume keys that the
  box sends over HDMI-CEC) and they want it to trigger something in Home
  Assistant.

## Step 1: gather what you need from the user

Ask, and record the answers:

| Question | Why |
|---|---|
| TV box model and its IP address? Can it have a fixed address (DHCP reservation)? | `adb_host`; the add-on does not follow IP changes. |
| Which buttons should do what? | Decides `keys`. Default volume up/down and mute. |
| What should the buttons control? (e.g. soundbar through an IR blaster) | Decides the automation. |
| How do you reach Home Assistant? UI only, or API token / SSH too? | Decides which install and verify steps you can do yourself. |
| Are they comfortable with the security trade-offs (Rule 1)? | Consent. |
| Is a Bluetooth keyboard paired to the TV? | If yes, flag the cleartext-input risk strongly. |

## Step 2: prepare the TV box (the user does this on the TV)

1. Enable Developer options, then network/USB debugging so the box listens on TCP
   port 5555. (On some boxes the setting does not survive a reboot.)
2. Note the box's IP address and set a DHCP reservation for it.
3. Check reachability from a machine on the same network:
   - with adb: `adb connect <ip>:5555` (it will say "unauthorized" until the prompt
     is accepted, which is fine), or
   - without adb: confirm TCP port 5555 is open (`nc -zv <ip> 5555`).
4. Keep the TV awake for the authorisation step (the prompt does not show over the
   screensaver). Waking it: `adb shell input keyevent KEYCODE_WAKEUP`.

If you can run `adb`, you can find key names now: `adb shell getevent -l`, press
the remote's buttons, and note lines like `EV_KEY  KEY_VOLUMEUP  DOWN`. The names
after `EV_KEY` are what go in `keys`.

## Step 3: install the add-on

**Option A, from the repository (preferred).** In Home Assistant: Settings ->
Add-ons -> Add-on Store -> menu (top right) -> Repositories -> add
`https://github.com/Daisame/keybridge` -> install **Keybridge**. (Newer
Supervisor versions call add-ons "apps"; the store works the same.)

**Option B, local copy** (if you have SSH access to the Home Assistant host's
Terminal & SSH add-on, port 22222 on HAOS by default). Copy the contents of
`adb_key_listener/` to the host's local-apps folder, then:

- Older Supervisor: the folder is `/addons/<name>/`.
- Supervisor 2026.10 and newer: `/local_apps/<name>/` (`/addons` does not exist).
- Files: `config.yaml`, `Dockerfile`, `build.yaml`, `run.sh`, `DOCS.md`. Make
  `run.sh` executable. Verify checksums after copying.
- `ha store reload`; the slug becomes `local_<name>` (e.g.
  `local_adb_key_listener`); `ha apps install local_adb_key_listener` (`ha addons`
  also works as an alias).
- After changing files of a local add-on, `ha apps rebuild` it (or bump the version
  in `config.yaml` and `ha apps update`). The script is baked into the image.

## Step 4: configure and start

Set the options (UI Configuration tab, or the Supervisor API; see below). At minimum
`adb_host`. Example:

```yaml
adb_host: "<tv ip>"
adb_port: 5555
event_type: adb_key
keys: [KEY_VOLUMEUP, KEY_VOLUMEDOWN, KEY_MUTE]
forward_repeat: false
```

Via the Supervisor API (only from a shell inside a Home Assistant add-on such as
Terminal & SSH, where `$SUPERVISOR_TOKEN` exists). This **replaces the whole
options object**, so send every option:

```bash
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"options":{"adb_host":"<tv ip>","adb_port":5555,"event_type":"adb_key","keys":["KEY_VOLUMEUP","KEY_VOLUMEDOWN","KEY_MUTE"],"forward_repeat":false}}' \
  http://supervisor/addons/<slug>/options
```

Then start the add-on. Option changes need a restart.

## Step 5: the user authorises the add-on on the TV

Tell the user to watch the TV. A dialog "Allow USB debugging?" appears with an RSA
fingerprint. After they have read the security notes they tick "Always allow from
this computer" and choose Allow. **Do not do this for them (Rule 2).**

If several prompts queue up (the add-on retries with a growing delay up to 2
minutes), accept them all. Confirm in the add-on log:

```
Connected to <ip>:5555; streaming key events
```

## Step 6: verify events

1. Developer Tools -> Events -> "Listen to events" -> `adb_key` -> Start listening.
2. Press a mapped button on the remote.
3. Expect a `down` then an `up` event with `key` set (for example `KEY_VOLUMEUP`).

The add-on log also shows `key KEY_VOLUMEUP down` and `up`. If nothing arrives,
see Troubleshooting.

## Step 7: build the automation (soundbar via an IR blaster, as an example)

If the user wants something else, adapt; keep the structure below.

1. **Learn the IR codes** with `remote.learn_command` on the IR blaster
   (Broadlink example): one command per button, `command_type: ir`, device name
   such as `soundbar`, commands `volume_up`, `volume_down`, `mute`, `power`.
   **Tell the user to TAP the button lightly.** Holding it records the repeat
   burst and then one send moves the volume about ten steps. The code for a clean
   tap is short.
2. **Test the codes**: `remote.send_command` once per command. Expect one step per
   send. IR gear often ignores the first send after idle (it only wakes its
   display), so test twice.
3. **Create the script and the automation** from
   [`examples/hold_to_repeat.yaml`](examples/hold_to_repeat.yaml): a
   `mode: restart` script that repeats, and an automation with event triggers for
   key down (start), key up and `adb_key_status: disconnected` (stop). Replace
   `remote.YOUR_BROADLINK` and the device name. You can paste the YAML in the UI,
   or create them over REST:
   - `POST /api/config/script/config/<id>` (entity becomes `script.<id>`)
   - `POST /api/config/automation/config/<id>` (new-style keys `triggers`,
     `actions`)
4. **Do not rebuild the repeat as a loop with `wait_for_trigger`.** It misses a
   key-up that arrives while it is sending, runs to its cap, and ignores new
   presses. See [`docs/DESIGN.md`](docs/DESIGN.md).
5. If a button is a toggle only (a single power code), say so. The automation
   cannot know the device's state; discuss what should happen if the device has
   turned itself off.

## Step 8: test with the user

| Do this | Expect |
|---|---|
| Tap Volume Up once | one step up |
| Tap Volume Down once | one step down |
| Hold Volume Up 2 to 3 seconds, release | steps on press, a short pause, then a steady ramp that stops when released |
| Hold until the volume reaches the top or bottom, release, press again | it responds immediately |
| Tap Mute | one mute toggle |

Check the automation trace if anything misbehaves. Many runs marked `failed_single`
mean runs overlapped (usually a lost key-up).

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| Log shows `Not ready (... device unauthorized)` | The prompt has not been accepted, or the TV is on its screensaver. Wake the TV; the user accepts "Always allow". The add-on retries with a delay up to 2 minutes; restart it to retry now. |
| Several "Allow USB debugging?" prompts | The retry loop asked repeatedly. Accept "Always allow" on each. Delays now grow, so this should not repeat. |
| Log shows `Connected but cannot read input events` | The box refused `getevent` for the ADB shell user. Keybridge will not work on that box. |
| Add-on starts then stops, log says `adb_host is not set` or `no valid keys` | Set a valid `adb_host`; keep at least one valid key name. |
| Pressing a button produces no `adb_key` event | The key name is not in `keys` (check with `adb shell getevent -l`), or the key goes to a different input device. Some buttons are IR-only on certain remotes and never reach the box. |
| Events arrive but nothing happens | The automation is off, trigger `event_data` does not match the key or state, or the script entity id differs from the one the automation calls. |
| Volume keeps going after release, or presses are ignored after reaching max | A loop-based repeat lost the key-up. Use the script plus `script.turn_off` pattern. |
| One press moves the volume about ten steps | The learned IR code is a repeat burst. Re-learn it with a light tap. |
| IR does nothing the first time | The device was idle and only woke its display. Send twice. |
| `adb_key_status` events stop after a Home Assistant restart | They are transitions, not a heartbeat. Do not rely on them for durable state. |
| A held key floods events | The device sends auto-repeat and `forward_repeat` is on. Turn it off. |

## Step 9: finish up, and tell the user

Offer (do not impose):

- Exclude the events from the recorder if they do not want them stored:
  `recorder: exclude: event_types: [adb_key]`.
- Isolate the TV on its own network and restrict port 5555 to the Home Assistant
  host.
- A DHCP reservation for the TV, if not already done.
- Encrypt their Home Assistant backups (they contain the ADB key) and note how to
  revoke it (TV Developer options -> Revoke USB debugging authorizations).
- Turn network debugging off on the TV if they stop using Keybridge.

Finish with a short summary of what was installed, which keys are forwarded, what
each automation does, and the security trade-offs they accepted. Remind them the
project is a hobby project without an independent audit.

## Things not to do

- Do not click the ADB "Allow" prompt for the user.
- Do not add typed keys (letters, digits) to `keys`.
- Do not forward port 5555 or expose ADB beyond the local network.
- Do not turn `forward_repeat` on without a reason (it is off by default), and do
  not leave repeating automations uncapped.
- Do not edit `automations.yaml` by hand while Home Assistant is running; use the
  UI or the config API.
- Do not paste tokens into chat, logs or files that will be committed.
