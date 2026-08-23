# Build references

Consult these while building. Local shell source wins on any conflict.

- Omarchy manual, shell plugins: https://omarchy.org/manual/shell-plugins/
- Plugin development guide: https://omarchyplugins.com/develop.html
- Shell README (manifest schema, IPC, shell.json rules): $OMARCHY_PATH/shell/README.md
- First-party plugin reference: $OMARCHY_PATH/shell/plugins/README.md
- Reference overlay implementation: $OMARCHY_PATH/shell/plugins/clipboard/Clipboard.qml
- Theme tokens: $OMARCHY_PATH/shell/Commons/{Color,Style,Border}.qml
- Sibling plugin with bar-widget + overlay + service: ~/code/omarchy-omaday

Known discrepancy: the manual shows entryPoints key `bar-widget`; the installed
shell and every first-party manifest use `barWidget`. Use `barWidget`.
