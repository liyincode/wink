# CLI and agents

[Back to README](../README.md)

## Usage

Open Wink first. The caller must run as the same macOS user as Wink and have permission to execute local commands and access the local socket.

From the source directory:

```sh
./scripts/wink blackout
./scripts/wink restore
./scripts/wink status --json
```

The script invokes `build/Wink.app`; run `bash scripts/build.sh` first. For an app installed in `/Applications`, use:

```sh
"/Applications/Wink.app/Contents/MacOS/Wink" blackout
"/Applications/Wink.app/Contents/MacOS/Wink" restore
"/Applications/Wink.app/Contents/MacOS/Wink" status --json
```

Adjust the path if Wink is installed elsewhere.

## Instructions for an agent

This example assumes Wink is installed in `/Applications/Wink.app`. Adjust the path before using it.

```text
Wink is running on this Mac. When I ask to black out the screens, restore
my displays, or check their state, use these commands:

Black out: "/Applications/Wink.app/Contents/MacOS/Wink" blackout
Restore: "/Applications/Wink.app/Contents/MacOS/Wink" restore
Status: "/Applications/Wink.app/Contents/MacOS/Wink" status --json

Read the returned JSON to determine the result.
blackout and restore wait for the transition to finish; repeated calls do not toggle.
If unavailable is returned, ask me to open Wink first.
For interrupted, timeout, or transport_error, query status before deciding to retry.
Do not substitute screen locking, system sleep, or black overlays for Wink blackout.
```

## Responses

`blackout` darkens all displays; `restore` restores their previous appearance. Both commands wait for the transition to finish and are idempotent. A repeated request for the same target waits for the current animation. An opposing command, shortcut, or other restore action interrupts the request with `interrupted`. Like manual restoration, `restore` skips the current scheduled period.

All three commands write one line of JSON to standard output; `--json` is optional. The exit code is `0` on success and `1` on failure. Use `--help` for usage. Example success response:

```json
{"ok":true,"status":{"progress":0,"recoveryPending":false,"scheduleEnabled":false,"state":"visible","target":"visible"},"version":1}
```

| Field | Meaning |
| --- | --- |
| `version` | Response format version, currently `1` |
| `ok` | Whether the query or operation succeeded |
| `status.state` | `visible`, `black`, `darkening`, `restoring`, or `recovery_required` when display state has changed and restoration is still needed |
| `status.target` | Current target: `black` or `visible` |
| `status.progress` | Transition progress: `0` is the original appearance; `1` is full blackout |
| `status.recoveryPending` | Whether Gamma recovery records remain; `true` during normal blackout or when disconnected displays still have pending records |
| `status.scheduleEnabled` | Whether scheduling is enabled |

State describes the Gamma session for currently connected displays, not whether their backlights are off. After connected displays are restored, `state: visible` and `recoveryPending: true` can coexist if records for disconnected displays remain. A successful `status` query can return `recovery_required`; use `restore` in that case.

Failure responses contain `error.code` and `error.message`, without `status`. Agents should use the stable error code; messages may follow the system language.

| Error code | Action |
| --- | --- |
| `not_built` | Build with `bash scripts/build.sh` |
| `unavailable` | Open Wink; commands do not launch the app automatically |
| `invalid_arguments`, `invalid_request` | Check the command and arguments |
| `interrupted`, `timeout`, `transport_error` | Query status before retrying; an error does not guarantee that the operation was not executed |
| `recovery_required`, `operation_failed`, `display_error` | Check display connections and the message, then use `restore`; keep recovery records if restoration fails |
| `busy` | Wait for the pending request to finish, then retry |
| `access_denied` | Run as the same macOS user as Wink |

Communication uses a per-user Unix socket with directory permissions `0700` and socket permissions `0600`. Both peers verify the other user's identity. The running Wink process executes commands through the same transition and recovery logic as the UI.
