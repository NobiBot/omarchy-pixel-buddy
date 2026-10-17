# Pixel Buddy

Your own pixel-art desktop buddy for Omarchy. It's a fork of
[chthollyphile/omarchy-agent-pet](https://github.com/chthollyphile/omarchy-agent-pet) with the same behavior:
idling, random actions, walking, drag and throw, click reactions, and Claude Code / Codex work status in a speech bubble.
The animations come from sprite packs you draw yourself, and a bar widget manages them.

## Install

```bash
git clone https://github.com/NobiBot/omarchy-pixel-buddy ~/.config/omarchy/plugins/nobi.pixel-buddy
```

Then add `{ "id": "nobi.pixel-buddy" }` to `plugins` and to `bar.layout.right` in `~/.config/omarchy/shell.json`.
On first start the buddy creates `packs/` and the default pack, Goop, from `templates/buddy.aseprite` and `templates/pack.json`.
Needs `jq`, `socat`, `notify-send`, `inotify-tools`, `python-pillow` and `qt6-imageformats`.
After changing the plugin's QML yourself, run `omarchy restart shell`.

## Sprite packs

Every buddy design is a **pack**: a folder in `packs/` holding the art plus an optional `pack.json`.
`packs/` is a symlink to `~/.local/share/pixel-buddy/packs/`. Omarchy reloads every plugin when a file
inside `~/.config/omarchy/plugins/` changes, and the symlink keeps pack edits and rebuilds from
triggering that. Goop, the slime, is the `default` pack (`templates/buddy.aseprite` and `templates/pack.json`,
with its geometry and phrases, recreate it on a fresh install); duplicate it from its right-click menu
if you want to start from the slime.

A pack can mix these formats:

| Files | Becomes |
|---|---|
| `*.aseprite` / `*.ase` | one animation per tag (a file without tags is one animation named after the file); a tag's Repeat is baked in |
| `name.png` + `name.json` | a sprite sheet: an Aseprite/LibreSprite JSON export, or `{"frameWidth":128,"frameHeight":72,"fps":10,"animations":{"idle":[0,3],"walk":{"from":4,"to":11}}}` |
| `name.png` alone | a horizontal strip of 16:9 (or square) frames |
| `name.gif` / `name.webp` | one ready-made animation called `name` |

Draw the buddy facing left, or set "drawn facing: Right" in the editor. Any canvas works: the
builder pads it to 16:9 and keeps the feet on the bottom edge.

### Walking

The buddy walks on its own: every time an animation ends it picks what to do next, by default idle 55%,
turn 15%, walk 15%, random action 15% (`animationWeights` in the config), split evenly between the
animations in each role. The Behavior tab gives each idle, walk, turn and random-action animation its
own **chance %**; ones left on auto share what the others leave, in the same proportions. A walk plays an animation
from the **walk** role (one walk cycle is enough; it loops for the whole trip) while the buddy slides
across the screen at the pack's walk speed (Behavior tab, canvas pixels per second). It walks the way
it faces. With a **turn** animation it turns around now and then; without one it picks a direction
for every walk and simply flips. Right-click the buddy → the walk entry starts a walk right away.

The buddy is centred on its hitbox, so a character drawn off-centre on the canvas still walks and
flips in place; set the hitbox around the body with the geometry editor's **Fit to sprite**.

### The bar widget

Add `nobi.pixel-buddy` to the bar (it sits in `bar.layout.right` of `~/.config/omarchy/shell.json`).
The icon is your buddy's first idle frame. **Left-click** opens the popup and **right-click** hides or
shows the buddy.

- **Home:** previews the selected pack (‹ › steps through its roles), shows how many roles are
  mapped, and lists every pack. Click a pack to look at it and **Use for <buddy>** to switch to it
  (double-click does both). **Right-click** a pack for Use, Edit, Duplicate, Open folder and Delete
  (asks first, then moves the pack to `~/.local/share/pixel-buddy/trash/`). **+ New** creates a pack with a blank 128×72 Aseprite canvas (one frame tagged
  `idle`), puts it on the buddy and opens it in Aseprite. **Aseprite**, **Rebuild** and **Folder** act on the selected pack.
- **Edit pack → Roles:** the buddy asks for roles (idle, walk, the six work states, …), not tag names.
  The widget guesses each role from your animation names ("Stand" → idle, "run_cycle" → walk,
  "Think" → thinking). Dropdowns fix the rest. Roles with several animations pick one at random.
  A role with nothing mapped is skipped: the buddy just carries on (a work state still shows in the bubble). **Guess again** forgets your choices. Your source files
  are never renamed: the mapping is stored in `pack.json`.
- **Behavior:** how long each animation loops, walk speed, and the chance % of each idle, walk, turn and
  random action being picked next (like a phrase's chance; ↺ puts one back on auto).
- **Geometry:** which way the art faces, the on-screen size, and **Open geometry editor**: drag
  the feet line and the hitbox (click/drag area; the speech bubble sits on its top edge) over a
  zoomed frame. The buddy follows live, and Save writes `pack.json`.
- **Phrases** (also a button on Home for the selected pack): what a buddy using this pack says in
  its speech bubble for each work state (thinking, working, reviewing, waiting for you, success,
  error), so each sprite can have its own voice. Edit a line and press Enter, add one in the
  "+ add a line" field, × removes it, ▶ shows it on the buddy. Each time the state changes a line
  is picked by its **chance %**; a state with no lines shows no bubble. Lines left on auto share
  whatever % the others leave, so by default every line is equally likely. If every line has its own %
  and they add up to less than 100, the rest of the time the buddy says nothing (the tab shows how often);
  ↺ puts a line back on auto. A pack without its own lines uses
  `workStatusTexts` from the config; the first edit copies those into the pack, and **Reset to defaults** goes back.
  Below the work states, **Animations** lists every animation in the pack by its tag name, custom names
  included. Give one some lines and each time that animation starts the buddy says one, picked by the
  same chance %. Give lines on idle or walk a low % (a work status, murmur or chat in the bubble takes priority).
- **Info:** name, author, files, build warnings, Duplicate, Delete (moves the pack to
  `~/.local/share/pixel-buddy/trash/`).

Saving a source file rebuilds its pack about a second later, and the buddy switches to the new
frames on its own. To rebuild by hand: `bin/pixel-buddy-pack build [pack] [--force]`. Builds go to
`~/.cache/pixel-buddy/` (safe to delete). Aseprite is found on PATH or in your Steam library, or set
`ASEPRITE=/path/to/aseprite`. The builder needs `python-pillow` and `inotify-tools`.

Each buddy's pack choice is stored in `~/.config/pixel-buddy/ui.json`. A buddy can also name one in
`config.jsonc` (`"buddies": [{ "id": "main", "pack": "mochi", … }]`), and the widget's choice wins.

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
  "behavior": { "playSec": { "Dance": 0 }, "speed": { "run_cycle": 30 }, "chance": { "Nap": 5 } },  // chance: % picked next, left out = auto
  "phrases": [                               // work-status bubble lines, same order as workStatus; left out = the config's
    ["Hmm…"], ["On it!"], ["Checking…"], ["Your turn!"], ["Done!"], ["Oops."]
  ],
  "animPhrases": {                           // said when that animation starts
    "Nap": ["zzz…", "five more minutes"],    // no chance = share what's left of 100%
    "Stand": [{ "text": "Nice day.", "chance": 5 }]   // 5% of the time; silent the other 95%
  }
}
```

## Roles and the default pack's tag names

| Role | Tag names |
|---|---|
| Idle loop | `idle` |
| Turn around (should end facing the other way) | `turn` |
| Held by the mouse | `drag` |
| Left-click reactions, picked at random | `click-hop`, `click-surprised` |
| Walking: a walk cycle that loops while the plugin slides the buddy at `speed` | `walk` |
| Random actions | `sleep`, `stretch` |
| Work status, in this order: thinking, working, reviewing, waiting for you, success, error | `work-thinking`, `work-working`, `work-reviewing`, `work-waiting`, `work-success`, `work-error` |
| Usage level, 6 tiers from 0% to 100% used | `usage-plenty` ×2, `usage-ok` ×2, `usage-low`, `usage-empty` |
| Murmur bubble | `whisper` |

To add more, draw a new animation and add it to a role in the widget's Roles tab.

## Config

Defaults are in `assets/config.json`. Your overrides go in `~/.config/pixel-buddy/config.jsonc` (comments allowed), and they apply on save.
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
  "buddies": [{ "name": "Pixel", "id": "main", "size": 384, "position": { "corner": "bottom-right", "marginX": 24, "marginY": 0 } }]
}
```

- **Walk speed** is `animations.moves.default.speed`, in canvas pixels per second (default 24). You can override it per walk in `moves.actions[].params`. The walk cycle repeats for as many whole loops as the trip takes. Without a `speed`, the buddy uses the original behavior: one play of the animation, stretched by `minPlaySec`.
- **Timing:** the builder records each animation's real loop length, so held frames and per-frame durations are timed correctly.
- **`size`** is the on-screen width when the pack sets no `scale`. Keep it a whole multiple of the canvas width (384 = 128 × 3) so pixels stay square and even.
- **`whisperPrompt`** is the buddy's personality for murmurs and chat.
- **Stickers:** put PNGs in `assets/memes/` and list them under `memes` as `"file name without .png": "when to use it"`. Chat and murmur bubbles can then show them.
- **Other options** (physics, usage, LLM, step summaries) work like the original. See the [agent-pet configuration reference](https://github.com/chthollyphile/agent-pet#configuration).

## Work status (Claude Code / Codex)

Install the hooks once. This backs up and edits `~/.claude/settings.json` and `~/.codex/hooks.json`:

```bash
~/.config/omarchy/plugins/nobi.pixel-buddy/bin/pixel-buddy-install-hooks             # --uninstall to remove
```

This plugin uses its own names everywhere: `pixel-buddy-hook`, socket `$XDG_RUNTIME_DIR/pixel-buddy/`, config `~/.config/pixel-buddy/`,
state `~/.local/state/pixel-buddy/`, and IPC `omarchy-shell pixel-buddy …`. It can run next to the original Agent Pet without conflicts.
Needs `jq`, `socat`, `notify-send` and `qt6-imageformats` (for WebP).

## Commands

```bash
omarchy-shell pixel-buddy play work-success   # play an animation by name (handy for testing)
omarchy-shell pixel-buddy say "hello"
omarchy-shell pixel-buddy usage | whisper | toggle | reload | state
omarchy-shell pixel-buddy packs                 # list packs as JSON
omarchy-shell pixel-buddy usePack mochi         # all buddies; or main=mochi for one buddy
omarchy-shell pixel-buddy buildPack mochi | editGeometry mochi
omarchy-shell pixel-buddy-studio toggle | edit roles | edit phrases   # the bar popup (bind it to a key if you like)
```

## Credits

Credit goes to [agent-pet](https://github.com/chthollyphile/agent-pet) (MIT), which ported its behavior from
[dsh-pet](https://github.com/PC2005-cloud/dsh-pet) (MIT). See LICENSE.
