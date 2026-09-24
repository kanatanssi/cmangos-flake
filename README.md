## NixOS Build Workarounds & Sandbox Fixes

Building **CMaNGOS Classic** within a strict, network-isolated Nix sandbox requires bypassing downstream dependency fetch mechanisms (`FetchContent`) utilized by the upstream build system. The following workarounds are implemented inside the Nix flake derivation to achieve a completely deterministic, offline compile:

### 1. Decoupling the Upstream `zlib` Fetch
By default, `dep/src/CMakeLists.txt` attempts to perform a live Git clone of `madler/zlib` if it determines the host version does not match exact constraints or target configurations.
* **The Issue:** Nix builds run without internet access, causing the network pull to fail. Attempting to feed a static git repository directly via `FETCHCONTENT_SOURCE_DIR_ZLIB` causes compilation errors because the zlib build scripts attempt to rename files (`zconf.h`) inside the read-only Nix store directory.
* **The Fix:** We apply a `postPatch` regex replacement (`sed`) to hardcode the condition `if (NOT ZLIB_FOUND...)` to `if (FALSE)`. This safely skips the internal build process and routes CMake directly to its native fallback block, linking cleanly against the pre-compiled `pkgs.zlib` provided by Nixpkgs via `cmakeFlags`.

### 2. Splicing Out-of-Tree Modules (`PlayerBots`)
The `PlayerBots` framework is traditionally treated as a dynamic module loaded into the source hierarchy via a separate `FetchContent_Populate` phase.
* **The Issue:** Forcing `FETCHCONTENT_FULLY_DISCONNECTED=ON` prevents the downloader from triggering, but passing an external Nix input path directly into CMake triggers an out-of-tree path warning, and halts because it lacks an explicit build binary mapping directory destination.
* **The Fix:** We utilize the `preConfigure` hook to create the `src/modules/` directory path and recursively copy the `playerbots` flake input straight into the isolated build workspace (`src/modules/PlayerBots`). Read/Write permissions are recursively granted via `chmod +w`, allowing CMake to seamlessly utilize the codebase as a native, localized directory.
