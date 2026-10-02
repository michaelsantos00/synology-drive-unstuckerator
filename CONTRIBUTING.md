# Contributing

Contributions are welcome under the same [PolyForm Noncommercial License 1.0.0](LICENSE.md). A contribution that you send for this project is licensed under those terms. Do not send changes you are not allowed to license that way.

## Before you change behavior

Read [docs/safety.md](docs/safety.md). The rules there are the product. A change that deletes or overwrites a user's file before Synology has reported the replacement uploaded, or that signals `fileproviderd` or a Synology process, will not be accepted.

## Development

```bash
swift test
```

Inside a synced checkout (Synology Drive adds file attributes that break code signing of build products), use `swift test --scratch-path /private/tmp/unstuckerator-build`.

The deployment target is macOS 15. Building needs Swift 6.2 and a macOS SDK supporting macOS 15. Keep newer system APIs behind a check so the app still runs on macOS 15.

Comments should explain a constraint or an invariant a reader cannot see from the names.

## What to include

- A failing test for a parser, confirmation, or requeue change, then the change that makes it pass.
- A note in the pull request of what the user can lose if the change is wrong.

Do not add a dependency for something Foundation or Swift already does.
