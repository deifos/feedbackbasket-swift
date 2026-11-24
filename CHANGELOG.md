# 0.6.0

- Decode public card fields on board items: `title`, `description`, and `authorName`.
- Add optional `submitterName` and `showNamePublicly` to `submit`. Names are public only after the submitter opts in and the owner approves the feedback.
- Align with contract 3.11.0; administrator operations remain in the CLI and MCP.

# 0.5.0

- Decode `hiddenColumns` in public roadmap settings. Cards in hidden columns are not returned.
- The public roadmap `primaryColor` now matches the public board brand color.
- Align with contract 3.10.0; administrator operations remain in the CLI and MCP.

# 0.4.0

- Add public board pages with vote counts and current vote state.
- Add IP-based vote toggling and board submissions pending review.
- Add public roadmap cards and display settings.
- Align with contract 3.7.0; administrator operations remain in the CLI and MCP.
