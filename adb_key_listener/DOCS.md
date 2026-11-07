# Keybridge

Streams `getevent` from an Android TV / Google TV box over network ADB and
fires Home Assistant events for the keys you choose.

## Why

Some Android TV boxes send the remote's volume keys straight to the HDMI-CEC
volume handler. Accessibility-based tools (Button Mapper, Key Mapper) usually
never see them. The kernel still reports them, so this add-on reads the raw
input events over ADB instead. You get real key down / up events, which makes
hold-to-repeat automations straightforward.

## Setup

1. On the TV: enable Developer options, then network/USB debugging so the box
   listens on port 5555 (check with `adb connect <ip>:5555`). On some boxes the
   port setting does not survive a reboot; if the add-on cannot connect after a
   restart of the TV, enable it again.
2. Give the TV a fixed address (a DHCP reservation). The add-on does not follow
   an IP change.
3. Set `adb_host` (the TV's IP or hostname) in the add-on options and start the
   add-on. Restart the add-on after any later option change; options are read
   once at start.
4. The TV shows "Allow USB debugging?" once. Read the Security section below,
   then tick "Always allow" and accept. If the TV is showing a screensaver the
   prompt may not appear; wake the TV first. The key is stored in the add-on's
   persistent `/data`.
5. Press a key on the remote and watch Developer Tools -> Events for
   `adb_key`.

## Options

| Option | Default | Meaning |
|---|---|---|
| `adb_host` | (empty) | IP address or hostname of the TV. Required. Letters, digits, dots and hyphens only. |
| `adb_port` | 5555 | ADB TCP port. |
| `event_type` | `adb_key` | Event name fired for each key event (lowercase letters, digits, underscores). |
| `keys` | volume up/down, mute | Linux key names to forward, exactly as `getevent -l` prints them (e.g. `KEY_VOLUMEUP`, `KEY_POWER`). Add `KEY_POWER` if you want the power button. |
| `forward_repeat` | `false` | Also forward kernel auto-repeat (`repeat`) events. Off by default: a held key can generate dozens per second, and automations normally only need down and up. |

## Events

`adb_key` (name configurable):

```json
{ "key": "KEY_VOLUMEUP", "state": "down", "device": "/dev/input/event7" }
```

`state` is `down` or `up` (and `repeat` if `forward_repeat` is on). Down and up
posts are retried briefly if Home Assistant is slow, but they are not queued: if
Home Assistant is down, events are lost.

`adb_key_status` (event name + `_status`): `{ "status": "connected" | "disconnected" | "unavailable" }`.
These are **transitions**, fired only when the status changes, not a periodic
heartbeat. After a Home Assistant restart nothing is re-sent until the next
change, so for a durable state build a trigger-based template or helper from
them. Use `disconnected` to stop repeating automations if the link drops
mid-press.

See `examples/hold_to_repeat.yaml` in the repository for a complete automation.
Always cap repeating automations: a lost key-up event would otherwise leave a
volume ramp running.

## Security considerations

- **"Always allow" is a permanent credential.** Accepting it gives whoever holds
  the add-on's ADB key a shell on the TV: install and remove apps, take
  screenshots, inject input, read shared storage, reboot. Some inexpensive boxes
  ship with ADB authentication disabled, which means anyone on the network has
  that access. Only enable network debugging on a TV you control.
- **ADB over TCP is not encrypted, and the add-on reads every input device.**
  The whole `getevent` stream crosses your LAN in cleartext and is filtered to
  your `keys` only afterwards, inside the add-on. A passive listener on the same
  network could see everything typed on a Bluetooth keyboard attached to the
  TV. Put the TV on a separate VLAN or restrict port 5555 to the Home Assistant
  host, and never forward port 5555 through your router.
- **The add-on holds a full-access Home Assistant API token** (`homeassistant_api`
  is the only permission the Supervisor offers for firing events). Treat the add-on
  as trusted code. The image is built locally from the repository.
- **The ADB private key lives in the add-on's `/data/.android` and is included in
  Home Assistant backups.** Anyone with a backup and access to the TV's network
  could use it. To revoke: on the TV, Developer options -> "Revoke USB debugging
  authorizations". To rotate: stop the add-on, delete `/data/.android`, start it
  again and accept the new prompt.
- **Key presses are Home Assistant events.** Every integration, automation and
  administrator can see them, anything holding an API token can fire a forged
  `adb_key` event, and the recorder may store them for a while. Keep the `keys`
  list short and do not add typing keys. If you do not want them kept, exclude
  the event type in the recorder configuration (`recorder: exclude: event_types:
  [adb_key]`).
- Each forwarded key event is written to the add-on log.
- Input is validated: option values are checked by the schema and again at
  start, only configured key names are forwarded, and the event body is built
  with `jq`, so a misbehaving device cannot add fields to an event.

## Notes and limitations

- Reads raw kernel key names. To find the names for other buttons, run
  `adb shell getevent -l` and press the key.
- The TV still performs its normal action for the key (for example sending CEC
  volume). This add-on observes; it does not consume the key.
- Reconnects automatically, with a delay that grows from 10 s to 2 minutes
  while the TV is unreachable or keeps dropping. A heartbeat every 20 s detects
  a silently dead link after two missed beats (up to about a minute).
- Not tested on devices other than the Onn 4K Pro so far.
