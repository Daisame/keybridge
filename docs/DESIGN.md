# Design notes: why Keybridge works the way it does

This records the reasoning behind the main choices, including the things we
tried first that did not work and the bugs we hit. Read it before changing the
reconnect or repeat logic: several details exist because of real failures.

Everything here was observed on one setup (Onn 4K Pro, Home Assistant OS 18.3,
Core 2026.10, a Broadlink IR blaster, a soundbar with IR only). Where a statement
is general rather than observed, it says so.

## The problem

On the Onn 4K Pro, pressing **Volume Up** on the Bluetooth remote did nothing
useful: the box sent a HDMI-CEC "volume up" to the TV, and the TV ignored it. The
goal was to use those buttons to drive a soundbar through Home Assistant and an
IR blaster instead.

## What we tried first (and why it failed)

| Approach | Result |
|---|---|
| **An accessibility remapper (Button Mapper)** with a mapping for Volume Up | Never fired. Even its "press the button to add" mode ignored the volume key, while other keys registered. The key is consumed by the system's volume/CEC handling before accessibility services see it. A public project that forwards Android keys to Home Assistant (HomeKeyTV) reportedly documents the same limit (system keys such as volume cannot be remapped); we did not verify that independently. |
| **Home Assistant's Android TV Remote or ADB integrations** | They send commands *to* the box. They do not report presses *from* the remote. `androidtv.learn_sendevent` captures one press for a few seconds, so it cannot stream. |
| **Listening to HDMI-CEC** | A forum thread we found reports receiving arrow keys but not volume keys. Not pursued or tested here. |
| **Turning off CEC volume on the box** | Not tried. It would not make the key visible to apps. |

What did work: `adb shell getevent -l` shows the press as `KEY_VOLUMEUP`, `DOWN`
then `UP`, from the remote's input device, with no root. That became Keybridge.

## Decisions

### Read kernel events over network ADB
The kernel reports every key regardless of what Android does with it afterwards.
The cost is real: network ADB is unencrypted and "Always allow" is a permanent
credential (see [SECURITY.md](../SECURITY.md)). We accepted that because nothing
safer exposed the volume keys on this device, and documented the risk plainly.

### Fire Home Assistant **events**, not entity states
A button press is momentary. Events carry exactly what we need (which key, down
or up) and fit automations naturally. The downside is that events are visible
to everything on the bus and cannot be "read back" later, which is why status
events are documented as transitions and why SECURITY.md says to keep the key
list short.

### Send **down and up**, not a single "pressed"
Hold-to-repeat needs to know when the key is released. Taps still work: a tap is
a down and an up in quick succession.

### Do the repeating in a **script that the key-up cancels**
Our first automation looped (`send`, then `wait_for_trigger` for the key-up) and
had two visible symptoms: the volume kept going after release, and after
reaching the top or bottom, new presses were ignored for a long time. Cause:
`wait_for_trigger` only listens while it is waiting. A key-up that arrives while
the loop is busy sending is lost; the loop then runs to its cap, and in
`mode: single` every new press is dropped (`failed_single` in the automation
trace). The fix is a `mode: restart` script that repeats, and a *separate*
trigger on the key-up that calls `script.turn_off`. Cancellation cannot miss.
Do not "simplify" this back into a loop.

### Forward only configured keys, and drop auto-repeat by default
The add-on only forwards key names you list. Kernel auto-repeat (`REPEAT`) events
are off unless you set `forward_repeat`: the Onn remote emitted none in testing,
but other devices may send dozens per second, and because events are posted one at
a time, a flood could delay the key-up behind a backlog. Repeating is the
automation's job.

### One `curl` per event, in order
Simple and correct. We rejected backgrounding the posts or adding a queue:
reordering a down and an up is worse than being slow. With repeat dropped there
are only two events per press, so the per-event cost does not matter. Down and
up posts are retried briefly because a lost up leaves a volume ramp running.

### Status events are transitions
`adb_key_status` fires only when the state changes (connected, disconnected,
unavailable). Firing on every retry created event spam while the TV was off.
Consequence: after a Home Assistant restart nothing is re-sent until the next
change, so consumers that need durable state should build a helper from them.

### Reconnect carefully
- **Back off from 10 s to 2 minutes.** Every connect attempt can raise an "Allow
  USB debugging?" prompt on the TV; the first version retried every 10 s and
  queued about ten prompts.
- **Prove `getevent` works before declaring "connected".** Otherwise a box that
  accepts the connection but refuses the stream would flap forever.
- **Back off when the stream dies young** (under a minute), and keep adb's error
  text in the log.
- **Timeouts on `adb connect` and `get-state`**, so a sleeping box cannot hang the
  loop.
- **A heartbeat that needs two failures**, so a briefly busy TV does not drop the
  link.
- **The script stops adb by PID** and handles `SIGTERM`, so there are no orphaned
  processes and a final "disconnected" event is sent.

### Validate everything, build JSON with `jq`
A review found that the `device` field of the event came from the first word of
whatever the TV sent and went into the JSON unchecked, which let a hostile TV
forge a key that was not in your list. The body is now built with `jq`, the device
path is validated, and options are checked twice (schema, then script).

### Do not filter on the TV by default
Running `getevent | grep` on the box would stop other devices' input crossing the
network. The two reviewers disagreed on it: one worried that the box's `grep`
may buffer its output and delay the key-up (we did not test this), and it needs
careful quoting on a device we cannot test broadly. We documented the exposure and recommend network
isolation. An opt-in "only read this input device" option is a possible
future change.

### Accept the `homeassistant_api` permission
It is the only way the Supervisor lets an add-on fire events, and it is broad. A
webhook with a secret ID would be narrower but changes the event model and puts
a secret in the options. Documented instead.

### Build locally; do not pin yet
There is no prebuilt image, so Home Assistant builds from the repository.
The base image tag is unpinned (`:latest`). We did not pin it because a wrong tag
breaks every build, and Home Assistant's build configuration conventions are
changing. If you fork this, pin the base image.

## A caveat we chose to live with: toggle-only IR power

The soundbar here has a single IR power-**toggle** code, no discrete on or off,
and no way for Home Assistant to read its state (the old Harmony hub's database
for it also lists only a toggle; Harmony avoided trouble by remembering the
state itself). The soundbar powers itself off after a few minutes of silence.

So if the soundbar has auto-powered off while the TV was on but silent, pressing
the box's power button sends a toggle that turns the soundbar **on**; it then
powers itself down again after a few minutes. If everything is off and you turn it
all on, it works normally. We considered a state-aware design (a power-state
event from the box's screen on/off log, plus a "grace window" after turning the
box off) and decided the simple behaviour was an acceptable trade-off. If your
device has discrete on/off codes, use them and the problem does not exist.

## What we observed on the Onn 4K Pro (do not assume it is universal)

- The remote appears as the input device `Onn-Remote Keyboard` and sends
  `KEY_VOLUMEUP`, `KEY_VOLUMEDOWN`, `KEY_MUTE` and `KEY_POWER`.
- No auto-repeat events were seen while holding a key.
- Network ADB stayed reachable while the box was in standby.
- The "Allow USB debugging?" prompt does not appear over the screensaver.
- The volume key is also sent by the box as HDMI-CEC; the TV ignored it.
- The box reports only 32-bit architectures even though the hardware is 64-bit;
  this does not affect the add-on, which uses the container's `adb`.

## IR blaster notes (from the example setup)

- When learning a code, **tap** the button lightly. Holding it records the
  remote's repeat burst, and then one send moves the soundbar about ten steps.
  A clean tap is a short code (roughly 115 to 130 characters in a Broadlink
  code).
- The first IR send after the soundbar has been idle may only wake its display.
  Test with two sends.

## Not done, and ideas

- Pin the base image and move to the current Home Assistant build layout.
- An opt-in option to read a single input device (less data on the network).
- A power-state event from the box's screen on/off log, for state-aware power
  handling.
- A webhook mode that avoids the broad API token.
- Prebuilt, signed images from CI.
- De-duplicating events if a device exposes the same key on two input nodes.
