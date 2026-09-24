# Keybindings hint for Omarchy

Hold `SUPER` and a bar slides up along the bottom of the screen listing what
every `SUPER + key` binding does, like [which-key](https://github.com/folke/which-key.nvim)
in Neovim. Let go of `SUPER` and it fades away.

![The keybindings bar](preview.png)

- **Grouped:** bindings are sorted into columns (Workspaces, Focus, Windows,
  Clipboard, Apps & menus, Other). Groups longer than six entries wrap into a
  second column so the bar stays short.
- **Keycaps:** keys are drawn as keycaps and show as they read on the keyboard
  (`'`, `;`, `⌫`, `←`, …). The ten workspace keys fold into one `1–0` entry.
- **Always your bindings:** the list is read from
  `omarchy menu keybindings --print`, so your own bindings and their
  descriptions show up too.
- **Never in the way:** the bar doesn't take the keyboard. Press a key while it
  shows and that binding runs as normal.
- **Fits the screen:** each column is as wide as its text. On narrower screens
  the text shrinks to fit rather than being cut off.
- **Themed:** colors and font come from the current Omarchy theme.
- **On/off switch:** turn the hint off when you don't want it. The setting is
  remembered across restarts.

## Install

```sh
omarchy plugin add https://github.com/Nejcc/omarchy-kebindings-hint.git --enable
```

Then add to `~/.config/hypr/bindings.lua`:

```lua
-- Keybindings hint: hold SUPER to show the bar, release SUPER to hide it.
hl.bind("SUPER_L", hl.dsp.exec_cmd("omarchy-shell shell summon nejcc.keybindings-hint"), { long_press = true, ignore_mods = true })
hl.bind("SUPER + SUPER_L", hl.dsp.exec_cmd("omarchy-shell shell hide nejcc.keybindings-hint"), { release = true })
hl.bind("SUPER_L", hl.dsp.exec_cmd("omarchy-shell shell hide nejcc.keybindings-hint"), { release = true })

-- Turn the hint on or off.
o.bind("SUPER + SHIFT + K", "Toggle keybindings hint", "omarchy-shell shell summon nejcc.keybindings-hint '{\"enabled\":\"toggle\"}'")
```

The long-press binding has to be on bare `SUPER_L` with `ignore_mods = true`.
Bound as `SUPER + SUPER_L` it never fires, because `SUPER` doesn't count as
held yet at the moment the key goes down.

`SUPER + SHIFT + K` is free in the default Omarchy bindings, next to Omarchy's
own `SUPER + K` keybindings menu. Pick another key if you prefer.

## Usage

| Shortcut | Does |
|---|---|
| hold `SUPER` | Show the bar; release to hide it |
| `SUPER + SHIFT + K` | Turn the hint on or off (a notification says which) |

### Commands

```sh
# Show or hide the bar with any key you like instead of holding SUPER
omarchy-shell shell toggle nejcc.keybindings-hint

# Turn the hint on, off, or flip it
omarchy-shell shell summon nejcc.keybindings-hint '{"enabled":"on"}'
omarchy-shell shell summon nejcc.keybindings-hint '{"enabled":"off"}'
omarchy-shell shell summon nejcc.keybindings-hint '{"enabled":"toggle"}'
```

While the hint is off, a marker file exists at
`~/.local/state/nejcc.keybindings-hint.disabled` (or under `$XDG_STATE_HOME`).
Deleting it and restarting the shell turns the hint back on.

## Limitations

- Only plain `SUPER + key` bindings are listed, not `SUPER + SHIFT + key` and
  other combinations.
- Groups are guessed from words in each description, because Omarchy's list
  has no categories. Anything unmatched lands in Other.
- If a release is missed, the bar hides itself after 6 seconds.
- On screens narrower than about 1900 logical pixels the text shrinks to fit,
  down to 9px. Below about 1250px the last column can still be cut off.
- After editing the plugin files, run `omarchy restart shell`. The shell's
  automatic reload doesn't always pick up changes.

## License

MIT
