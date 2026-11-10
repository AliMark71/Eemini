# Eemini

A Discord bot that copies custom emoji into your personal Matrix emote pack, written in Swift.

Link your Matrix account, then use `/copy` with a Discord emoji. Eemini downloads the image, uploads it to your homeserver, and adds it to your `im.ponies.user_emotes` account data under the emoji's name.

> [!WARNING]
> **Work in progress.** Account links are stored only in memory, and the bot currently requires an existing personal emote pack. Back up your pack before trying it: updates re-encode the pack using a limited data model, so unrecognized fields are not preserved.

## Requirements

- A Swift toolchain compatible with the package's Swift 6.5 tools version.
- On macOS, the package declares macOS 27 as its minimum deployment target.
- A Discord bot token and access to the bot's slash commands in Discord.
- A Matrix account on an HTTPS homeserver, with an access token for that account.
- An existing personal emote pack and a Matrix client that supports `im.ponies.user_emotes`.

## Building & Running

This project uses the Swift Package Manager, so you can apply your ~~nonexistant~~ knowledge from there, but some basics:

From the repository root, with the appropriate Swift toolchain selected:

```sh
swift build # this build (obviously)
swift run # this build and runs
```

The bot prompts for its Discord token on standard input if `EEMINI_BOT_TOKEN` is unset. This prompt does not hide typed input. For unattended use, supply `EEMINI_BOT_TOKEN` through your process environment or secret manager.

For a release build:

```sh
swift build -c release
.build/release/Eemini # dis da executable
```

On startup, Eemini connects to Discord and bulk-registers its global application commands. This replaces the application's existing global command set, so use a dedicated Discord application.

## Commands

### `/setup`

Link your Discord user to a Matrix account:

```text
/setup homeserver:https://matrix.example.org token:<matrix-access-token>
```

Supply your homeserver's base URL, not your Matrix user ID. Eemini validates the token against the homeserver's `whoami` endpoint to determine your Matrix user ID.

Run this once per bot session. A second setup for the same Discord user is rejected; changing homeservers is not currently supported without restarting the bot.

> [!NOTE]
> Eemini doesn't support delegation yet. Provide the base URL that serves your homeserver's client–server API directly, which may differ from the domain in your Matrix user ID.

### `/set-token`

Replace the token for your linked Matrix account:

```text
/set-token token:<new-matrix-access-token>
```

Run `/setup` first. The new token must belong to the same Matrix account.

### `/copy`

Pass exactly one custom Discord emoji in the `emoticon` option:

```text
/copy emoticon:<:tsodinPog:796788674523824158>
/copy emoticon:<a:reximRave:1291458064377188472>
```

Unicode emojis, stickers, image URLs, and multiple emoji in one command are not supported.

The emoji is added under its Discord name, such as `:wave:`. Existing names are never overwritten. There is no separate rename option.

## Credentials and visibility

- Matrix tokens are submitted as Discord command arguments and handled by the bot. Only use an instance whose operator you trust.
- `/setup` and `/set-token` responses are ephemeral; `/copy` responses are not.
- Account links and Matrix tokens are held in process memory, not persisted by Eemini. Restarting clears every link, but does not revoke the tokens or remove copied emotes from Matrix.

## Current limitations

- Eemini does not create a personal emote pack. The existing account-data event must decode into the structures in `Eemini.swift`, including `pack`, `images`, and image metadata.
- Pack updates use a read–modify–write cycle. Concurrent edits can overwrite each other, and fields outside Eemini's data model are dropped.
- Images are limited to 1 MiB, and existing pack data to 50 KiB.
- Uploads happen before duplicate-name and image-metadata checks, so a failed copy can leave uploaded media that is not referenced by the pack.
- Error handling is incomplete; some failures may leave an interaction without a final response.
