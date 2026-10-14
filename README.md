# Pixel Pet

Your own pixel-art desktop pet for Omarchy. It's a fork of
[chthollyphile/omarchy-agent-pet](https://github.com/chthollyphile/omarchy-agent-pet) with the same behavior:
idling, random actions, walking, drag and throw, click reactions, and Claude Code / Codex work status in a speech bubble.
The animations come from sprite packs you draw yourself, and a bar widget manages them.

## Install

```bash
git clone https://github.com/NobiBot/omarchy-pixel-pet ~/.config/omarchy/plugins/nobi.pixel-pet
```

Then add `{ "id": "nobi.pixel-pet" }` to `plugins` and to `bar.layout.right` in `~/.config/omarchy/shell.json`.
On first start the pet creates `packs/` and a Default pack from `templates/pet.aseprite`.
Needs `jq`, `socat`, `notify-send`, `inotify-tools`, `python-pillow` and `qt6-imageformats`.
After changing the plugin's QML yourself, run `omarchy restart shell`.

## Sprite packs

Every pet design is a **pack**: a folder in `packs/` holding the art plus an optional `pack.json`.
`packs/` is a symlink to `~/.local/share/pixel-pet/packs/`. Omarchy reloads every plugin when a file
inside `~/.config/omarchy/plugins/` changes, and the symlink keeps pack edits and rebuilds from
triggering that. The original slime is the `default` pack, and `templates/pet.aseprite` is the starter
file for new packs.

A pack can mix these formats:

| Files | Becomes |
|---|---|
| `*.aseprite` / `*.ase` | one animation per tag (a file without tags is one animation named after the file); a tag's Repeat is baked in |
| `name.png` + `name.json` | a sprite sheet: an Aseprite/LibreSprite JSON export, or `{"frameWidth":128,"frameHeight":72,"fps":10,"animations":{"idle":[0,3],"walk":{"from":4,"to":11}}}` |
| `name.png` alone | a horizontal strip of 16:9 (or square) frames |
| `name.gif` / `name.webp` | one ready-made animation called `name` |

Draw the pet facing left, or set "drawn facing: Right" in the editor. Any canvas works: the
builder pads it to 16:9 and keeps the feet on the bottom edge.

### The bar widget

Add `nobi.pixel-pet` to the bar (it sits in `bar.layout.right` of `~/.config/omarchy/shell.json`).
The icon is your pet's first idle frame. **Left-click** opens the popup and **right-click** hides or
shows the pet.

- **Home:** previews the selected pack (‹ › steps through its roles), shows how many roles are
  mapped, and lists every pack. Click a pack to look at it and **Use for <pet>** to switch to it
  (double-click does both). **+ New** copies the Aseprite template into a new pack and opens it in
  Aseprite. **Aseprite**, **Rebuild** and **Folder** act on the selected pack.
- **Edit pack → Roles:** the pet asks for roles (idle, walk, the six work states, …), not tag names.
  The widget guesses each role from your animation names ("Stand" → idle, "run_cycle" → walk,
  "Think" → thinking). Dropdowns fix the rest. Roles with several animations pick one at random.
  A role with nothing mapped plays idle. **Guess again** forgets your choices. Your source files
  are never renamed: the mapping is stored in `pack.json`.
- **Behavior:** how long each animation loops, walk speed, and how often each random action plays.
- **Geometry:** which way the art faces, the on-screen size, and **Open geometry editor**: drag
  the feet line and the hitbox (click/drag area; the speech bubble sits on its top edge) over a
  zoomed frame. The pet follows live, and Save writes `pack.json`.
- **Info:** name, author, files, build warnings, Duplicate, Delete (moves the pack to
  `~/.local/share/pixel-pet/trash/`).

Saving a source file rebuilds its pack about a second later, and the pet switches to the new
frames on its own. To rebuild by hand: `bin/pixel-pet-pack build [pack] [--force]`. Builds go to
`~/.cache/pixel-pet/` (safe to delete). Aseprite is found on PATH or in your Steam library, or set
`ASEPRITE=/path/to/aseprite`. The builder needs `python-pillow` and `inotify-tools`.

Each pet's pack choice is stored in `~/.config/pixel-pet/ui.json`. A pet can also name one in
`config.jsonc` (`"pets": [{ "id": "main", "pack": "mochi", … }]`), and the widget's choice wins.

`pack.json`, if you'd rather write it by hand:

```jsonc
{
  "name": "Mochi", "author": "you",
  "facing": "left", "scale": 3,              // on-screen width = canvas width × scale
  "feetY": 66, "hitBox": [46, 38, 82, 67],   // canvas pixels; left out = measured from the idle animation
  "minPlaySec": 5,
  "roles": {                                 // only the roles you set; the rest are guessed
    "idle": ["Stand"], "walk": ["run_cycle"], "clicks": ["Boing", "Blush"], "actions": ["Nap", "Dance"],
    "workStatus": ["Think", "Type", "Read", "Wait", "Yay", "Oops"],   // null = guess, "" = idle
    "balance": [null, null, null, null, "Tired", "Empty"]
  },
  "behavior": { "playSec": { "Dance": 0 }, "speed": { "run_cycle": 30 }, "weight": { "Nap": 2 } }
}
```

## Roles and the default pack's tag names

| Role | Tag names |
|---|---|
| Idle loop | `idle` |
| Turn around (should end facing the other way) | `turn` |
| Held by the mouse | `drag` |
| Left-click reactions, picked at random | `click-hop`, `click-surprised` |
| Walking: a walk cycle that loops while the plugin slides the pet at `speed` | `walk` |
| Random actions | `sleep`, `stretch` |
| Work status, in this order: thinking, working, reviewing, waiting for you, success, error | `work-thinking`, `work-working`, `work-reviewing`, `work-waiting`, `work-success`, `work-error` |
| Usage level, 6 tiers from 0% to 100% used | `usage-plenty` ×2, `usage-ok` ×2, `usage-low`, `usage-empty` |
| Murmur bubble | `whisper` |

To add more, draw a new animation and add it to a role in the widget's Roles tab.

## Config

Defaults are in `assets/config.json`. Your overrides go in `~/.config/pixel-pet/config.jsonc` (comments allowed), and they apply on save.
Each **top-level** key you write replaces the default key as a whole. So if you override `animations`, copy the full block.

`sprite` is the fallback geometry and timing for packs that don't set their own:

```jsonc
{
  "sprite": {
    "width": 128, "height": 72,     // canvas size, 16:9
    "feetY": 66,                    // pixel row the feet stand on
    "hitBox": [46, 38, 82, 67],     // x0, y0, x1, y1: the click/drag/bubble area
    "fps": 10,                      // your frame rate; used to time walks
    "minPlaySec": 5,                // short loops (idle, actions, walks, events) repeat until at least this long
    "playSec": { "walk": 3 }        // per-animation override in seconds; 0 = play once
  },
  "pets": [{ "name": "Pixel", "id": "main", "size": 384, "position": { "corner": "bottom-right", "marginX": 24, "marginY": 0 } }]
}
```

- **Walk speed** is `animations.moves.default.speed`, in canvas pixels per second (default 24). You can override it per walk in `moves.actions[].params`. The walk cycle repeats for as many whole loops as the trip takes. Without a `speed`, the pet uses the original behavior: one play of the animation, stretched by `minPlaySec`.
- **Timing:** the builder records each animation's real loop length, so held frames and per-frame durations are timed correctly.
- **`size`** is the on-screen width when the pack sets no `scale`. Keep it a whole multiple of the canvas width (384 = 128 × 3) so pixels stay square and even.
- **`whisperPrompt`** is the pet's personality for murmurs and chat.
- **Stickers:** put PNGs in `assets/memes/` and list them under `memes` as `"file name without .png": "when to use it"`. Chat and murmur bubbles can then show them.
- **Other options** (physics, usage, LLM, step summaries) work like the original. See the [agent-pet configuration reference](https://github.com/chthollyphile/agent-pet#configuration).

## Work status (Claude Code / Codex)

Install the hooks once. This backs up and edits `~/.claude/settings.json` and `~/.codex/hooks.json`:

```bash
~/.config/omarchy/plugins/nobi.pixel-pet/bin/pixel-pet-install-hooks             # --uninstall to remove
```

This plugin uses its own names everywhere: `pixel-pet-hook`, socket `$XDG_RUNTIME_DIR/pixel-pet/`, config `~/.config/pixel-pet/`,
state `~/.local/state/pixel-pet/`, and IPC `omarchy-shell pixel-pet …`. It can run next to the original Agent Pet without conflicts.
Needs `jq`, `socat`, `notify-send` and `qt6-imageformats` (for WebP).

## Commands

```bash
omarchy-shell pixel-pet play work-success   # play an animation by name (handy for testing)
omarchy-shell pixel-pet say "hello"
omarchy-shell pixel-pet usage | whisper | toggle | reload | state
omarchy-shell pixel-pet packs                 # list packs as JSON
omarchy-shell pixel-pet usePack mochi         # all pets; or main=mochi for one pet
omarchy-shell pixel-pet buildPack mochi | editGeometry mochi
omarchy-shell pixel-pet-studio toggle | edit roles   # the bar popup (bind it to a key if you like)
```

## Credits

Credit goes to [agent-pet](https://github.com/chthollyphile/agent-pet) (MIT), which ported its behavior from
[dsh-pet](https://github.com/PC2005-cloud/dsh-pet) (MIT). See LICENSE.
