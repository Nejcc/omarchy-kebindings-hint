# Keybindings hint for Omarchy

Hold `SUPER` and a bar along the bottom of the screen lists what every
`SUPER + key` binding does, like [which-key](https://github.com/folke/which-key.nvim)
in Neovim. Let go of `SUPER` and it disappears.

![The keybindings bar](preview.png)

- The list is read from `omarchy menu keybindings --print`, so it includes your
  own bindings and their descriptions.
- The bar never takes the keyboard: press a key while it shows and that binding
  runs as normal.
- Keys show as they read on the keycap (`'`, `;`, `⌫`, `←`, …), and the ten
  workspace keys fold into one entry.
- Colors come from the current Omarchy theme.

## Install

```sh
omarchy plugin add https://github.com/Nejcc/omarchy-kebindings-hint.git --enable
```

Then add to `~/.config/hypr/bindings.lua`:

```lua
-- Show on a long press of SUPER, hide when SUPER is released.
hl.bind("SUPER + SUPER_L", hl.dsp.exec_cmd("omarchy-shell shell summon nejcc.keybindings-hint"), { long_press = true })
hl.bind("SUPER + SUPER_L", hl.dsp.exec_cmd("omarchy-shell shell hide nejcc.keybindings-hint"), { release = true })
hl.bind("SUPER_L", hl.dsp.exec_cmd("omarchy-shell shell hide nejcc.keybindings-hint"), { release = true })
```

Prefer a normal key? Bind `omarchy-shell shell toggle nejcc.keybindings-hint`
to anything you like.

## Limitations

- Only plain `SUPER + key` bindings are listed, not `SUPER + SHIFT + key` and
  other combinations.
- If a release is missed, the bar hides itself after 6 seconds.
- On screens narrower than about 1900 logical pixels the text shrinks to fit,
  down to 9px; below about 1250px the last column can still be cut off.

## License

MIT
