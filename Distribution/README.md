# Distribution

- Use `Packages` for generating the `pkg`.
- All plugins are separate packages allowed end users to customize which plugins they want to install.
- `<Plugin>.app` are installed to `/Applications/Keyframeless`.
- The `postinstall` script automatically moves the package templates into the correct Motion Templates folder.

## Version Management

- Each package has its own version inside `Packages` tool.
- Additionally, versions need to be bumped in the `Info.plist` of the corresponding plugin.