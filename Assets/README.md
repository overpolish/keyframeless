# Assets

`keyframeless.icon` supplies the MagicMove application icon, and the icns Xcode builds from it is also put on the installer package. `installer.svg` is the installer's artwork, the mark on a transparent canvas so one image serves both appearances; `scripts/build-pkg.sh` rasterizes it at the size it declares, so nothing generated is kept here. Plugin-specific resources belong with their consuming plugin; assets shared across plugins belong here.
