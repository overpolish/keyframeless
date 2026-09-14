# PluginPreferences

Foundation storage for plugin preferences. Each plugin supplies a stable `NSUserDefaults` suite and namespace. The package has no UI, FxPlug, or timing dependencies.

`PPDefaultStore` reads and writes property-list dictionaries. Callers supply a factory value and schema validator. Invalid stored values fall back to the factory value; invalid writes leave the saved value unchanged. Restoring a factory default removes the override. Separate keys can store defaults for different setting types without replacing each other's values.

Plugins decide when to apply preferences to newly created content. Document decoding, rendering, and undo should use saved document values.

```sh
swift build --package-path PluginPreferences
PluginPreferences/Tests/run.sh
```

Tests cover persistence, namespace and key isolation, invalid data, rejected writes, and restoring factory values.
