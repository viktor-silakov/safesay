# Configure safesay

## Configuration file

Settings are stored in `~/.config/safesay/config.json`. Set `mode` to either `foreground` or `background`. The `allowedApps` array lists the IDs of apps that can use the microphone while `safesay` speaks. The optional `paused` flag defaults to `false`.

```json
{
  "mode": "foreground",
  "allowedApps": ["com.example.Dictation"]
}
```

`safesay --mic-status` shows apps with active audio input, their IDs, and whether each is `allowed` or `blocked`. For a process without an app ID, the command may show the path to its executable. You can pass that path to `--allow-app`.

`safesay --list-allowed` shows saved exceptions, including apps that are currently closed. `safesay --remove-allowed <id>` removes one exception. `safesay --clear-allowed` clears all exceptions and keeps the selected mode.

## If a phrase is waiting

Run `safesay --status` to check whether speech is paused, the LaunchAgent is running, or an app is blocking speech. Run `safesay --mic-status` for process IDs and individual `blocked` or `allowed` entries. To release a microphone blocker, stop audio input in that app or add it to the exception list. A browser exception covers all tabs.

In background mode, exit code `0` means the command queued the phrase. Errors from `say`, such as an invalid voice name, appear in `~/Library/Application Support/safesay/worker.log`. Background mode requires a logged-in macOS user session.

Pending phrases are stored locally in `~/Library/Application Support/safesay/queue`. The agent removes a job after `say` exits, after cancellation, or when it reaches an expired job. If the agent stops mid-phrase, the job remains on disk and can replay the next time the agent starts if its lifetime has not expired.

Use `safesay --queue` to find a job ID and `safesay --cancel <id>` to cancel it. Queue listings omit expired jobs. In foreground mode, a phrase that expires while waiting is skipped and the command reports the expiration. A phrase that starts before its deadline can finish playing.

## Uninstall

Run `safesay --mode foreground`. If phrases are queued, wait for the LaunchAgent to speak them and stop. Then remove the executable at `~/.local/bin/safesay`. You can remove the settings and log separately if you no longer need them.
