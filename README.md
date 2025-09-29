# Stage Manager

Stage Manager is a macOS utility that offers CLI and daemon tooling for managing Stage Manager across spaces. The project provides XPC-based control, LaunchAgent integration, and a convenient `--toggle-current` flag to switch the Stage Manager state for the active Mission Control space.

## Raycast Integration

A Raycast script command is available to trigger `StageManager --toggle-current` directly from the Raycast launcher.
wx 
### Installation

1. Build or install the Stage Manager CLI so the `StageManager` binary is available on your `PATH`, or keep this repository locally with a built product inside `.build`.
2. Copy or symlink the script command into Raycast's script directory:

   ```bash
   mkdir -p "$HOME/.raycast/scripts/StageManager"
   ln -sf "$(pwd)/Resources/Raycast/toggle-stage-manager-current.sh" "$HOME/.raycast/scripts/StageManager/toggle-stage-manager-current.sh"
   ```

   Adjust the source path if your repository is stored elsewhere.
3. In Raycast, open **Settings → Extensions → Script Commands** and click **Add Folder** if the StageManager folder is not yet listed.
4. Run the command "Toggle Stage Manager (Current Space)" from Raycast's command palette.

### Configuration

- If the `StageManager` CLI is not on your `PATH`, set `STAGE_MANAGER_BIN` in the script command configuration (Raycast → Edit Command) to point to the binary.
- The script automatically falls back to any `.build/release/StageManager` or `.build/debug/StageManager` binary located two levels above the script directory. As a final fallback, it runs `swift run StageManager --toggle-current` from the repository root.

### Troubleshooting

- **"StageManager CLI not found"**: Ensure the binary exists at one of the checked locations or export `STAGE_MANAGER_BIN` with the absolute path.
- **Permission denied**: Make sure the script is executable: `chmod +x Resources/Raycast/toggle-stage-manager-current.sh`.
