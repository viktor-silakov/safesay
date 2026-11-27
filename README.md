# safesay

`safesay` uses macOS `say` to speak text. It can hold voice notifications while the microphone is in use during calls, dictation, or recordings.

## Installation

Building requires macOS 15 or later and Xcode tools with macOS SDK 15 or later.

```sh
git clone https://github.com/viktor-silakov/safesay.git
cd safesay
./install.sh
safesay 'Done'
```

The installer builds `safesay`, copies it to `~/.local/bin`, and adds that directory to `PATH` through `.zshenv`. In new zsh sessions, the command works from any directory. Run the installer again to update it. The installer restarts the LaunchAgent if it is loaded.

## Modes

The first time you run `safesay` in a terminal, with a phrase or with no arguments, it prompts you to choose a mode. Press Enter to choose foreground. Running it with no arguments in a terminal shows help and returns to the prompt.

1. **Foreground.** The command waits for the microphone, speaks the phrase, and returns the exit status from `say`.
2. **Background.** The command adds the phrase to an on-disk queue and returns immediately. A user LaunchAgent waits for new jobs in the background.

The selected mode is stored in `~/.config/safesay/config.json`. If no mode is set and no terminal is available, the command uses foreground mode for that run. You can also set the mode directly.

```sh
safesay --mode foreground
safesay --mode background
safesay -v Alex 'Task complete'
printf '%s\n' 'Task complete' | safesay
```

File output (`-o`) and queries such as `-v '?'` run immediately. Use `safesay -f -` to type text in the terminal. Typed input, `--progress`, and `--interactive` run in the current terminal. When you switch to foreground mode, the LaunchAgent finishes its queue and stops.

## Queue and playback

- `safesay --queue` lists queued jobs with their IDs, ages, and text previews.
- `safesay --cancel 3` cancels job `3`.
- `safesay --clear-queue` cancels all queued jobs.
- `safesay --pause` pauses speech and keeps accepting background jobs.
- `safesay --resume` resumes speech when the microphone allows it.
- `safesay --status` shows the mode, pause state, LaunchAgent status, queue size, and microphone blockers.

A phrase expires after two hours of waiting by default. Add `--ttl` before the `say` arguments to set a different lifetime. Use seconds, minutes, or hours, such as `30s`, `5m`, or `2h`.

```sh
safesay --ttl 5m 'Task complete'
```

Pausing speech interrupts the current phrase. It starts again from the beginning after you resume, provided it has time left to wait. Lifetimes continue to count down while speech is paused.

## Short options

- `-p` pauses speech, `-R` resumes it, and `-s` shows status.
- `-q` lists the queue and `-c <id>` cancels a job.
- `-m <mode>` selects a mode and `-t <duration>` sets a phrase's lifetime.
- `-l` lists saved microphone exceptions and `-M` shows active microphone users.
- `-h` shows help and `-v` on its own shows the `safesay` version.

`-v Alex` selects a voice, `-v '?'` lists voices, and `-r <rate>` sets the speech rate, as in macOS `say`.

## Microphone exceptions

```sh
safesay --mic-status
safesay --allow-app com.example.Dictation
safesay --allow-current
safesay --list-allowed
safesay --remove-allowed com.example.Dictation
safesay --clear-allowed
```

`--allow-current` adds all apps currently using audio input. `--mic-status` shows their IDs and whether each app is allowed. `--list-allowed` displays all saved exceptions. Use `--remove-allowed` to remove one entry or `--clear-allowed` to remove them all.

Speech waits as long as Core Audio reports an active input from any app outside the exception list. If an app outside the list starts recording mid-phrase, `safesay` stops `say` at the next microphone check and repeats the phrase from the beginning when speech is allowed again. Muting a call may leave audio input active. A browser exception applies to the entire browser.

[Configuration, troubleshooting, and uninstalling](docs/configuration.md)

## Tests

```sh
swift test
```
