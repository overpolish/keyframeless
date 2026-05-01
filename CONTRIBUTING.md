# Contributing

## Set-up

- Install [workflow extension SDK](https://developer.apple.com/download/all/?q=WorkflowExtensions)

...

## Troubleshooting

> [!IMPORTANT]
> macOS registers apps with Launch Services from every location — including Trash, archives, and archive intermediates. If you delete or move a copy of the wrapper app, stale registrations stick around and `pluginkit` can end up parenting the extension to a host app that no longer exists. FCP silently skips it.
>
> Unregister stale paths and re-register the debug build:
>
> Note: the `[ ! -e "$p" ]` guard isn't enough - building the `KeyframelessKit` scheme directly produces its own host app + appex in a separate DerivedData folder that still exists on disk, so two copies share a bundle ID and Launch Services keeps preferring the older one. Unregister by path mismatch instead:
>
> ```sh
> LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
> KEEP="$(pwd)/DerivedData/Keyframeless/Build/Products/Debug/Keyframeless X.app"
>
> # unregister every copy except the debug build
> $LS -dump | grep -B20 'identifier:.*co.overpolish.keyframeless.Keyframeless-X$' \
>   | grep "path:" | sed 's/.*path: *//; s/ (0x.*//' \
>   | while read -r p; do
>       [ "$p" != "$KEEP" ] && $LS -u "$p" && echo "Unregistered: $p"
>     done
>
> # re-register the debug build
> $LS -f -R -trusted "$KEEP"
> pluginkit -a "$KEEP/Contents/PlugIns/Keyframeless X FCP.appex"
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

### "Module map file not found" error

If clangd reports `Module map file '…/DerivedData/…/module.modulemap' not found`, the `.clangd` config has drifted to reference DerivedData-generated paths that don't exist yet. The fix is to keep a static `module.modulemap` in the source tree and point `.clangd` at that instead.

`KeyframelessKit/KeyframelessKit/module.modulemap` already exists for this purpose. If `.clangd` ever regresses to a DerivedData path, update the `-fmodule-map-file` flag back to:

```
-fmodule-map-file=/path/to/repo/KeyframelessKit/KeyframelessKit/module.modulemap
```
