# Contributing

## Set-up

- Install [workflow extension SDK](https://developer.apple.com/download/all/?q=WorkflowExtensions)

...

## Troubleshooting

> [!IMPORTANT]
> macOS registers apps with LaunchServices even from Trash. If an FCP extension stops showing up in Final Cut Pro, stale copies of the wrapper app (in Trash, archives, etc.) with the same bundle ID can confuse `pluginkit` about which extension to load. Empty Trash and unregister stale entries:
>
> ```sh
> # List all registrations for the bundle ID
> /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump | grep -B10 "co.overpolish.keyframeless.Keyframeless-X$" | grep -E "path|identifier"
>
> # Unregister a stale path
> /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "/path/to/stale/Keyframeless X.app"
>
> # Force re-register the debug build
> /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/path/to/DerivedData/.../Debug/Keyframeless X.app"
>
> # Enable the extension if pluginkit shows it as disabled (!)
> pluginkit -e use -i co.overpolish.keyframeless.Keyframeless-X.Keyframeless-X-FCP
> ```
>
> Restart FCP after fixing registrations.

## VSCode

If you're using VSCode with clangd, run the following after building the project to generate the language server config:


```sh
# List available schemes
xcodebuild -workspace Keyframeless.xcworkspace -list
```

```sh
# Build `Keyframeless X FCP` scheme
xcode-build-server config -workspace Keyframeless.xcworkspace -scheme "Keyframeless X FCP"
```

Re-run with a different scheme if you're editing files in that target. Then restart the language server.