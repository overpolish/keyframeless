# Contributing

## Set-up

- Install [workflow extension SDK](https://developer.apple.com/download/all/?q=WorkflowExtensions)

...

## Troubleshooting

> [!IMPORTANT]
> macOS registers apps with Launch Services from every location — including Trash, archives, and archive intermediates. If you delete or move a copy of the wrapper app, stale registrations stick around and `pluginkit` can end up parenting the extension to a host app that no longer exists. FCP silently skips it.
>
> Check for stale entries (`fnfErr` = file gone):
>
> ```sh
> LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
>
> $LS -dump | grep -B20 'identifier:.*co.overpolish.keyframeless.Keyframeless-X$' | grep -E "^path|^bundle id|not found"
>
> # ! = disabled, + = enabled
> pluginkit -m -A -p com.apple.FinalCut.WorkflowExtension
> ```
>
> Unregister every stale path, then re-register the debug build:
>
> ```sh
> $LS -u "/path/to/stale/Keyframeless X.app"
>
> $LS -f -R -trusted "$(pwd)/DerivedData/Keyframeless/Build/Products/Debug/Keyframeless X.app"
>
> pluginkit -a "$(pwd)/DerivedData/Keyframeless/Build/Products/Debug/Keyframeless X.app/Contents/PlugIns/Keyframeless X FCP.appex"
> pluginkit -e use -i co.overpolish.keyframeless.Keyframeless-X.Keyframeless-X-FCP
> ```
>
> Restart FCP after fixing.

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