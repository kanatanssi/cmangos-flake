# CMaNGOS Classic WoW Server Configuration

This NixOS module provides a declarative way to host a CMaNGOS Classic (1.12) World of Warcraft server with integrated MariaDB database initialization, PlayerBots, and AHBot support.

## Usage

Add the flake to your system configuration and enable the service. You must manually extract the client assets (`maps`, `vmaps`, `mmaps`, `dbc`) from your WoW Classic client and place them into the `cmangosDataDir` (defaults to `/var/lib/cmangos`) before the world server can start.

```nix
{ inputs, ... }: {
  imports = [ inputs.cmangos-flake.nixosModules.default ];

  services.cmangos-server = {
    enable = true;
    openFirewall = true; # Opens port 3724 (auth) and 8085 (world)
    cmangosDataDir = "/var/lib/cmangos";

    # Optional credentials (defaults to "mangos" / "mangos")
    dbUser = "mangos";
    dbPassword = "your_secure_password";
  };
}
```

### Build workarounds and hacks
* **Boost**: Swapped `Boost_USE_STATIC_LIBS` to `OFF` via `substituteInPlace` because NixOS provides Boost as dynamic shared libraries (`.so`).
* **Offline builds**: Set `FETCHCONTENT_FULLY_DISCONNECTED=ON` in `cmakeFlags` to prevent CMake from trying to clone repositories over the network.
* **Zlib bypass**: Hack CMaNGOS's internal `FetchContent` check for Zlib to always return `FALSE`, forcing CMake to use the pre-compiled, stable Nixpkgs native library paths instead.
* **PlayerBots**: Copied the `playerbots` module directly into `src/modules/PlayerBots`, as cmake tries downloading it otherwise.
* **MariaDB**: Pointed `MYSQL_INCLUDE_DIR` and `MYSQL_LIBRARY` manually to the Nix system path of `mariadb-connector-c`.
* **Database password**: Set a password for dbUser via `mysql_native_password`. Default behavior is unix socket auth.
* **Just straight sql files**: Dropped upstream's interactive `InstallFullDB.sh` manager entirely because it breaks inside non-interactive systemd routines and I could not pass variables to it reliably.
* **Tmp workspace**: The main `.sql.gz` is extracted under a temporary directory, which is cleaned up after import.
* **Core update version check**: The classic-db ships with a lot of the updates already included. The check for these prints a lot of errors while checking. Each error means an update that was missing from the db, i.e. an update that should be applied.
* **Assets from client**: Left client data extraction (`maps`, `vmaps`, `mmaps`, `dbc`) out of the flake. User should ensure that assets are in cmangosDataDir, default `/var/lib/cmangos`.

### During development, test with
```
nix build .#nixosConfigurations.testVM.config.system.build.vm
./result/bin/run-nixos-vm

# run in terminal from project directory
QEMU_NET_OPTS="hostfwd=tcp::2222-:22" ./result/bin/run-nixos-vm -nographic
# exit vm with just a normal shutdown
shutdown now


# check init script logs with
journalctl -u cmangos-db-init --no-pager
```
