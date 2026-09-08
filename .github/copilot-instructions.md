# StreamRadios Copilot Instructions

- Never run `xcodebuild` or any command or task that builds the Xcode project. The user builds the project manually in Xcode.
- Never install or launch StreamRadios on a physical iOS device. The user handles all device builds and runtime validation.
- Static code inspection and editor diagnostics are allowed, but do not use them as a reason to trigger a build.
