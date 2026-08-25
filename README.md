# Osaurus Music

An Osaurus plugin for controlling Apple Music on macOS.

## Features

- **Playback Control**: Play, pause, skip tracks, and adjust volume
- **Playlist Playback**: Play any playlist from your library (recommended for streaming content)
- **Track Information**: Get details about the currently playing track
- **Library Search**: Search your music library and play specific songs
- **Playlist Browsing**: List your playlists and read the songs inside them
- **Library Stats**: View your library statistics

## Available Tools

### Playback Controls

| Tool             | Description              | Parameters                       |
| ---------------- | ------------------------ | -------------------------------- |
| `play`           | Resume or start playback | None                             |
| `pause`          | Pause playback           | None                             |
| `next_track`     | Skip to next track       | None                             |
| `previous_track` | Go to previous track     | None                             |
| `set_volume`     | Set volume level         | `level` (0-100)                  |
| `play_playlist`  | Play a playlist by name  | `playlist`, `shuffle` (optional) |

### Library Information

| Tool                | Description                        | Parameters         |
| ------------------- | ---------------------------------- | ------------------ |
| `get_current_track` | Get currently playing track info   | None               |
| `get_library_stats` | Get library statistics             | None               |
| `list_playlists`    | List available playlists           | `limit` (optional) |
| `get_playlist_tracks` | List the songs in a playlist     | `playlist`, `limit` (optional) |

### Search and Play

| Tool           | Description                      | Parameters                  |
| -------------- | -------------------------------- | --------------------------- |
| `search_songs` | Search for songs in your library | `query`, `limit` (optional) |
| `play_song`    | Search and play a specific song  | `song`                      |

### App Control

| Tool         | Description                                    | Parameters |
| ------------ | ---------------------------------------------- | ---------- |
| `open_music` | Open Apple Music (launches or brings to front) | None       |

## Note on Streaming Tracks

Due to macOS/AppleScript limitations, **individual streaming tracks** (from Apple Music catalog) may not auto-play when using `play_song`. The tool will report `"playing": false` in this case.

**Recommendation**: Use `play_playlist` for the most reliable playback experience with Apple Music streaming content. Playlists work reliably with both local and streaming tracks.

## Requirements

- macOS 15.0 or later
- Apple Music app installed
- Apple Music subscription (for streaming content)
- Automation permission (granted when first used)

## Development

1. Build:

   ```bash
   swift build -c release
   ```

2. Extract manifest (to verify):
   ```bash
   osaurus manifest extract .build/release/libosaurus-music.dylib
   ```
3. Package (for distribution):
   ```bash
   osaurus tools package osaurus.music 0.1.0
   ```
   This creates `osaurus.music-0.1.0.zip`.
4. Install locally:
   ```bash
   osaurus tools install ./osaurus.music-0.1.0.zip
   ```

## Permissions

This plugin requires the **Automation** permission to control Apple Music via AppleScript. When you first use any tool, macOS will prompt you to grant Osaurus access to control the Music app.

You can manage this permission in:
**System Settings > Privacy & Security > Automation**

## Publishing

This project includes a GitHub Actions workflow (`.github/workflows/release.yml`) that automatically builds and releases the plugin when you push a version tag.

To release:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## License

MIT
