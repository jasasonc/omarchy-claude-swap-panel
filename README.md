# Claude Swap Panel

An Omarchy bar plugin for people with more than one Claude account in [claude-swap](https://github.com/realiti4/claude-swap). It replaces the Agents panel. It shows the usage limits of each account, and it switches Claude Code between the accounts from the keyboard.

This plugin is not part of claude-swap. It only uses the `cswap` command.

![The panel with two claude-swap accounts: the active work account with the Add button, and the personal account with its switch button. Both tabs show the token charts for all accounts.](preview.png)

The plugin is a copy of the Omarchy Agents panel (`omarchy.agents`) with these changes:

- Each claude-swap account has its own tab. The tab name is the alias from `cswap alias`. If an account has no alias, the tab name is the part of the email address before the @. If two accounts have the same part before the @, the tabs show the full email addresses.
- The Claude tabs stay in the claude-swap account order. Key `1` always shows account 1, also after a switch.
- The active account shows `active` next to its plan.
- An inactive account has a switch button. From the keyboard, a switch needs two key presses, so a look at the usage never switches the account.
- The Add button at the top of the active account's tab opens a terminal that adds an account to claude-swap.
- If claude-swap is not installed, the Claude tab shows the install command.
- The bar icon warns about the limits of the active Claude account, also when the panel was last open on the tab of another account.
- The token charts show on each Claude tab, with the label `ALL ACCOUNTS`. Claude Code does not record the account in its session files, so the charts show the tokens of all accounts together.
- The panel shows the Claude accounts and Fireworks. It does not show Codex. If you track Codex usage, keep the stock Agents panel.
- A right-click on the bar icon does nothing.

## Requirements

- Omarchy 4.
- Claude Code.
- claude-swap. The plugin does not install it. To install it, run:

  ```
  uv tool install claude-swap
  ```

  The plugin looks for `cswap` only in `~/.local/bin` and in `~/.local/share/uv/tools/claude-swap/bin`. The Add account terminal looks for `claude` only in `~/.local/share/mise/installs/claude/latest`, `~/.local/bin` and `~/.claude/local`.
- Python 3 at `/usr/bin/python3`.

## Install

```
omarchy plugin add https://github.com/jasasonc/omarchy-claude-swap-panel.git --enable
```

The plugin takes the place of the Agents panel (`omarchy.agents`) in the bar. Do not enable a second copy of the Agents panel at the same time. The copies use the same panel commands and the same usage folder.

## Add accounts

Open the panel on the tab of the active account. Click `+ Add` at the top right, or push `a`. A terminal opens and does these steps:

1. claude-swap saves the account that Claude Code uses now.
2. You log in with the account to add. The login opens in the browser.
3. claude-swap saves the new account.
4. You can switch Claude Code back to the first account.

If the browser is signed in to claude.ai with a different account, the login uses that account. Sign out of claude.ai first.

To give the tabs short names, set aliases:

```
cswap alias 1 work
cswap alias 2 personal
```

## Hotkey

Omarchy has no default key for the Agents panel. To open the panel with `Super+Ctrl+U`, add this line to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + U", "Claude usage", "omarchy-shell omarchy.agents toggle")
```

## Keys in the panel

| Key | Action |
|---|---|
| `h`, `l`, or `1` to `9` | Show another tab |
| `s`, then `s` again | Switch Claude Code to the account on the tab |
| `a` | Add an account |
| `c` | Copy the install command, if claude-swap is not installed |
| `j`, `k` | Scroll |
| `r` or `Enter` | Refresh the numbers |
| `Esc` | Close the panel |

After the first `s`, the switch waits 3 seconds for the second `s`. If you change the tab or close the panel, the switch stops. With a mouse, click the switch button one time.

After a switch, a notification shows the result. Open Claude Code sessions use the new account from their next message.

## Settings

The plugin reads the usage of all accounts every 180 seconds. To change the interval, add `"cswapRefreshIntervalSec": 300` to the entry of the plugin in `~/.config/omarchy/shell.json`. The minimum is 60 seconds. The other settings are the same as in the Agents panel, but the plugin has no synced aggregation from other machines.

## How it works

- `bin/cswap-panel bridge` runs `cswap list --json`. It writes one usage record for each inactive account to `~/.local/state/omarchy/agents/usage/cswap-<name>.json`. The panel shows each record as a tab.
- The stock Claude collector writes the record of the active account. The plugin gives that tab the name of the active account, from `~/.local/state/cswap-omarchy/active.json`.
- The bridge also writes `~/.local/state/cswap-omarchy/status.json`. The panel gets the setup state from this file.
- The plugin runs the bridge when the shell starts, at the refresh interval, when the panel opens, and after a switch. claude-swap keeps its own usage cache, so the plugin sends no more usage requests than claude-swap does.
- If claude-swap cannot read the usage of an account, the tab shows the cause, for example `Sign-in expired`, and the last known numbers.

## Processes and files

- Each process that the plugin starts directly has an absolute program path and a closed environment. The Add account terminal starts through Omarchy and the session, so the plugin cannot close the environment of the terminal itself. The terminal runs `env -i`, and the script starts with a closed environment again. The environment has only `PATH=/usr/bin:/bin`, `OMARCHY_PATH`, `HOME`, `LANG`, `XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY`, and `CLAUDE_CONFIG_DIR` if it is set.
- `bin/cswap-panel run` starts each automatic process in its own process group. At a deadline, or when the output is larger than a limit, it stops the process and all processes that it started, also the processes that left the group. It also stops them when the process ends, and when the shell stops the runner.
- `bin/cswap-panel state` reads the usage records and the claude-swap state. The panel does not read these files itself. It only watches `status.json` for changes. The reader opens each folder and file without following symlinks. It accepts only folders and files that the user owns, and folders that the group and other users cannot write to. It reads at most 64 records, 1 MiB for each record, and 2 MiB in total.
- The bridge writes the files through the same folder checks. It writes a new file first, then renames it.
- The usage update is the unchanged Omarchy command `/usr/bin/omarchy-agent-usage-update`.
- Before the plugin runs `cswap` or `claude`, `bin/cswap-panel` checks the program. It follows each symlink itself, at most 8. Each folder on the way, from `/` down, must be owned by root or the user and not writable by group or others. The program must be a regular file with the same owner and write rules. `claude` must be an ELF program. A `cswap` script must have an absolute `#!` interpreter that is not `env`, and the interpreter must pass the same checks and be an ELF program. If a candidate fails, the plugin writes the reason and tries the next candidate.
- The program then starts through the file descriptor that passed the checks, not through its name. A script starts through the descriptor of its checked interpreter, and the interpreter reads the script from a descriptor. Thus the program that runs is the file that passed the checks.
- The usage update always skips the Codex collector, and `bin/cswap-panel state` ignores the Codex record.

## Update and remove

```
omarchy plugin update io.github.jasasonc.claude-swap-panel
```

To go back to the stock Agents panel:

```
omarchy plugin enable omarchy.agents
omarchy plugin remove io.github.jasasonc.claude-swap-panel
rm -f ~/.local/state/omarchy/agents/usage/cswap-*.json
rm -rf ~/.local/state/cswap-omarchy
```

## License

MIT. The panel code comes from the Omarchy Agents plugin by David Heinemeier Hansson, also under MIT.
