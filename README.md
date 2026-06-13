# OTCv8 Developer Edition

OTCv8 is a cross-platform Tibia client built with C++17, OpenGL, and Lua scripting. This repository contains the full source code and assets.

> **Note:** This is a community fork with fixes for modern toolchains (Boost 1.90, VS 2022+, vcpkg).

## Prerequisites (Windows)

Before compiling, you'll need:

1. **Visual Studio 2022 or later** with the following workloads:
   - "Desktop development with C++"
   - Windows SDK (10.0.26100.0 or later)

2. **CMake** (version 3.10+) — included with Visual Studio or [download](https://cmake.org/download/)

3. **Ninja** — included with Visual Studio or [download](https://github.com/ninja-build/ninja/releases)

4. **vcpkg** — package manager for C++ libraries
   ```powershell
   git clone https://github.com/microsoft/vcpkg
   cd vcpkg
   .\bootstrap-vcpkg.bat
   ```

5. **vcpkg dependencies** (install in one command):
   ```powershell
   vcpkg install boost-system boost-filesystem boost-asio boost-beast boost-uuid lua51 glew physfs zlib libzip bzip2 openssl --triplet x64-windows
   ```

6. **Git** for cloning the repository

## Compilation (Windows)

### Using Visual Studio (CMakeSettings.json)

1. Open the project folder in Visual Studio
2. Visual Studio will automatically detect `CMakeSettings.json`
3. Select the `x64-Debug` or `x64-Release` configuration from the dropdown
4. Build: **Build → Build All** (Ctrl+Shift+B)

### Using Command Line (Ninja)

Open a **Visual Studio Developer Command Prompt** (x64):

```cmd
cd C:\path\to\otcv8-dev-master
mkdir out\build\x64-Release
cd out\build\x64-Release
cmake ..\..\.. -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=C:/path/to/vcpkg/scripts/buildsystems/vcpkg.cmake
cmake --build .
```

The compiled executable will be at `out\build\x64-Release\otclient.exe`.

### Build Configurations

| Configuration | Description |
|---|---|
| `Release` | Optimized build for end users |
| `Debug` | Debug symbols, no optimizations — for development |

## Running

Run the client from the **project root directory** (where the `data/` folder lives):

```cmd
cd C:\path\to\otcv8-dev
otclient.exe
```

The client will load all modules from `data/`, `modules/`, `layouts/`, and `mods/`.

## Project Structure

| Path | Description |
|---|---|
| `src/` | C++ source code (client, framework, android) |
| `data/` | Game assets (images, fonts, sounds, shaders, styles) |
| `modules/` | Lua modules for game UI and logic |
| `layouts/` | UI layout definitions |
| `mods/` | Optional modifications |
| `init.lua` | Lua entry point for bootstrapping |

## Release Packages

Pre-built releases are available on the [Releases](https://github.com/joelslamospersson/otcv8-dev/releases) page:

- **Source code** — zip of the repository source
- **Ready-2-Run** — pre-compiled executable with all required DLLs and assets

## License

See [LICENSE](LICENSE) for details.
