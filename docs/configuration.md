# Configure safesay

## Configuration file

Settings are stored in `~/.config/safesay/config.json`. Set `mode` to either `foreground` or `background`. The `allowedApps` array lists the IDs of apps that can use the microphone while `safesay` speaks.

```json
{
  "mode": "foreground",
  "allowedApps": ["com.example.Dictation"]
}
```

`safesay --mic-status` shows apps with active audio input, their IDs, and whether each is `allowed` or `blocked`. For a process without an app ID, the command may show the path to its executable. You can pass that path to `--allow-app`.

`safesay --list-allowed` shows saved exceptions, including apps that are currently closed. `safesay --clear-allowed` clears all exceptions and keeps the selected mode. To remove a single exception, delete its entry from `allowedApps`.

## If a phrase is waiting

Run `safesay --mic-status`. Each `blocked` entry identifies a process that is holding an audio input open. Stop microphone capture in that app or add it to the exception list. A browser exception covers all tabs.

In background mode, exit code `0` means the command queued the phrase. Errors from `say`, such as an invalid voice name, appear in `~/Library/Application Support/safesay/worker.log`. Background mode requires a logged-in macOS user session.

Pending phrases are stored locally in `~/Library/Application Support/safesay/queue`. The agent removes a job after `say` exits. If the agent stops mid-phrase, the job remains on disk and can replay the next time the agent starts.

## Uninstall

Run `safesay --mode foreground`. If phrases are queued, wait for the LaunchAgent to speak them and stop. Then remove the executable at `~/.local/bin/safesay`. You can remove the settings and log separately if you no longer need them.
