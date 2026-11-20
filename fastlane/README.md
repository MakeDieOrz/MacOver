fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

All macOS build lanes target `PlayCover.xcworkspace` (`scheme: "PlayCover"`) and embed `PlayCoverHelper` and `PlayTools.framework` inside `MacOver.app`.

### release

```sh
[bundle exec] fastlane release
```

Builds the `Release` configuration (`Developer ID` export method).

### nightly

```sh
[bundle exec] fastlane nightly
```

Builds the `Nightly` configuration (`Developer ID` export method).

### notarize_app

```sh
[bundle exec] fastlane notarize_app
```



### notarize_dmg

```sh
[bundle exec] fastlane notarize_dmg
```



### rename_dmg

```sh
[bundle exec] fastlane rename_dmg
```



----


## Mac

### mac custom_lane

```sh
[bundle exec] fastlane mac custom_lane
```

Description of what the lane does

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
