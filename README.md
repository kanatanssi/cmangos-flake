# cmangos-flake

NixOS module and package for a CMaNGOS Classic 1.12 server: MariaDB setup, PlayerBots, AHBot, declarative game accounts. x86_64-linux only.

## Usage

```nix
{
  inputs.cmangos.url = "github:kanatanssi/cmangos-flake";

  outputs = { nixpkgs, cmangos, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        cmangos.nixosModules.default
        ({ config, ... }: {
          services.cmangos-server = {
            enable = true;
            openPorts = true; # 3724 (realmd), 8085 (mangosd)
            dbPasswordFile = config.sops.secrets.cmangos-db.path;
            gameAccounts = {
              perttupeikko = { passwordFile = config.sops.secrets.perttu.path;; gmLevel = 0; };
              hilmahaltia = { passwordFile = config.sops.secrets.hilma.path;; gmLevel = 2; };
            };
          };
        })
      ];
    };
  };
}
```

## Client data

Bring your own! Extract `maps`, `vmaps`, `mmaps` and `dbc` from your 1.12 client into `cmangosDataDir`, defaults to `/var/lib/cmangos/data`.

## Options

| Option | Default | Notes |
|---|---|---|
| `enable` | `false` | |
| `dbPasswordFile` | required | Path to a file with the DB password. Alphanumeric characters only Az-Zz 0-9. |
| `gameAccounts` | `{}` | See below. |
| `mangosdSettings` | `{}` | Any `mangosd.conf` key, see below. See cmangos-classic for available keys |
| `realmdSettings` | `{}` | Any `realmd.conf` key. See cmangos-classic for available keys |
| `openPorts` | `false` | Opens `realmdPort` and `mangosdPort`. |
| `realmdPort` / `mangosdPort` | `3724` / `8085` | |
| `cmangosDataDir` | `/var/lib/cmangos/data` | Extracted client data. Read-only for the service. |
| `cmangosWorkingDir` | `/var/lib/cmangos` | Holds `etc/` and `workingDir/`. cmangos finds its confs relative to the working dir, so they must stay parallel. |
| `user` | `cmangos` | System user running the daemons. |

## Secrets

All passwords are read from files at service start and never enter the Nix store. Use sops-nix or similar.

- DB password: Alphanumeric characters Az-Zz 0-9, - and _.
- Game account passwords: 3-16 alphanumeric characters Az-Zz 0-9, - and _.

## Bots: which ones, and why `BUILD_AHBOT` is OFF

CMaNGOS has two auction house bots and two playerbot implementations. The names overlap and it's easy to mix them up:

| | Core (mangos-classic) | Module ([cmangos/playerbots](https://github.com/cmangos/playerbots)) |
| :--- | :--- | :--- |
| **Playerbots** | old built-in playerbot (`BUILD_DEPRECATED_PLAYERBOT`) | **used**: `BUILD_PLAYERBOTS=ON`, placed under `src/modules/PlayerBots` |
| **AH bot** | `src/game/AuctionHouseBot`, built when `BUILD_AHBOT=ON` | **used**: `ahbot/`, built when `BUILD_AHBOT=OFF` |

The flake uses both bots from the playerbots module. `BUILD_AHBOT` turns on the *core AH bot*. When it is OFF, the module's AH bot takes its place, so `BUILD_AHBOT=OFF` means the AH bot from the module is in use. This is also upstream's default for a playerbots build.

The same split shows up in classic-db's `InstallFullDB.config`:
- `PLAYERBOTS_DB` applies the module's SQL (`src/modules/PlayerBots/sql`). `-InstallAll` turns it on by itself.
- `AHBOT` applies the *core AH bot's* GM commands (`sql/base/ahbot`), so the flake leaves it off.

The two AH bots also read different config:
- The core bot reads `AuctionHouseBot.*` keys with the `Mangosd_` prefix.
- The module bot reads `AhBot.*` keys with the `AHBot_` prefix.

`ahbotSettings` is for the module bot.

## Server config

`mangosd.conf`, `realmd.conf`, `aiplayerbot.conf` and `ahbot.conf` use as a baseline the `.dist` files from the repo. You can pass overrides with env vars in the module's settings. E.g.:

```nix
services.cmangos-server = {
  mangosdSettings = {
    Mangosd_PlayerLimit = "50";
    Mangosd_Rate_XP_Kill = "2";
  };
  realmdSettings = {
    Realmd_RealmsStateUpdateDelay = "20";
    Realmd_WrongPass_MaxCount = "0";
  };
  playerbotSettings = {
    PlayerBots_AiPlayerbot_MinRandomBots = "1000";
    PlayerBots_AiPlayerbot_ClassRaceProb_8_0 = "1000";
  };
  ahbotSettings = {
    AHBot_AhBot_MaxItemLevel = "500";
    AHBot_AhBot_MaxAuctionCount_equip_white = "500";
  };
};
```

| Configuration | env var prefix | link |
| :--- | :--- | :--- |
| **mangosd.conf** | Mangosd_ | [mangosd.conf.dist.in](https://github.com/cmangos/mangos-classic/blob/master/src/mangosd/mangosd.conf.dist.in) |
| **realmd.conf** | Realmd_ | [realmd.conf.dist.in](https://github.com/cmangos/mangos-classic/blob/master/src/realmd/realmd.conf.dist.in) |
| **aiplayerbot.conf** | PlayerBots_ | [aiplayerbot.conf.dist.in](https://github.com/cmangos/playerbots/blob/master/playerbot/aiplayerbot.conf.dist.in) |
| **ahbot.conf** | AHBot_ | [ahbot.conf.dist.in](https://github.com/cmangos/playerbots/blob/master/ahbot/ahbot.conf.dist.in) |


You can verify the prefixes from the repos. Mangosd and realmd confs say the prefix right in the header, for aiplayerbots and ahbots you find the header when the config is initialized:
- [mangosd.conf.dist.in](https://github.com/cmangos/mangos-classic/blob/master/src/mangosd/mangosd.conf.dist.in)
- [realmd.conf.dist.in](https://github.com/cmangos/mangos-classic/blob/master/src/realmd/realmd.conf.dist.in)
- [aiplayerbot.conf.dist.in](https://github.com/cmangos/playerbots/blob/master/playerbot/PlayerbotAIConfig.cpp)
- [ahbot.conf.dist.in](https://github.com/cmangos/playerbots/blob/master/ahbot/AhBotConfig.cpp)

## Database

On first start, `cmangos-db-init.service` runs upstream's `InstallFullDB.sh -InstallAll` non-interactively. It creates the base structures and imports world content and the PlayerBots SQL. The script needs MariaDB root, so it logs in as root over the unix socket. No root password is involved.

The install only runs if all four databases (`classicmangos`, `classiccharacters`, `classicrealmd`, `classiclogs`) are completely empty. If any of them has even one table, the install is skipped, so it can never drop a populated database. This also means a failed or interrupted install is **not** retried automatically. To reinstall, drop the databases and restart:

```
for db in classicmangos classiccharacters classicrealmd classiclogs; do sudo mariadb -e "DROP DATABASE $db"; done
sudo systemctl restart mysql cmangos-db-init
```

This deletes all characters and accounts.

On every start, including after a config change, the service also:
- switches the DB user to password auth, with the password from `dbPasswordFile`
- writes `realmAddress` and `mangosdPort` to the `realmlist` table, so realmd advertises the right address to clients

Logs: `journalctl -u cmangos-db-init`.


## Game accounts

You can define game accounts in the module's settings. E.g.:

```nix
services.cmanangos-server.gameAccounts = {
  perttupeikko = { passwordFile = "/run/secrets/perttupeikko"; gmLevel = 0; };
  hilmahaltia = { passwordFile = "/run/secrets/hilmahaltia"; gmLevel = 2; };
};

```

`cmangos-accounts.service` runs on every boot and ensures each account in `gameAccounts` exists, its password matches the password set in the password file, and its GM level matches the config (0 player, 1 mod, 2 dm, 3 admin).

Accounts are only ensured to exist, never deleted. Removing one from the config leaves it in the database; delete it manually. Names and passwords: 3 to 16 characters, alphanumeric, dash - or underscore _.

## Updating

If your server is running, it is probably best to just let it run. This flake does not offer automatic database migration, and a newer core can expect a newer schema and break things. Back up first and follow upstream's update procedure.

## Development

Core, classic-db and playerbots inputs all just point to the main branches, but the flake.lock has them pinned to specific commits.

Run test vm with:

```
nix build .#nixosConfigurations.testVM.config.system.build.vm
sudo ./result/bin/run-nixos-vm -nographic
```

The vm autologins as root. Its disk is the `.qcow2` in the directory you launch from; delete it for a clean database. The host's `/var/lib/cmangos` is shared into the VM, so put client data there.

## Build notes

- Boost: `Boost_USE_STATIC_LIBS` forced off, nixpkgs ships shared libraries.
- `FETCHCONTENT_FULLY_DISCONNECTED=ON`, cmake otherwise tries to pull zlib and Playerbots, instead...
- nixpkgs zlib is used and PlayerBots is added as an input and placed in cmangos' `src/modules/PlayerBots`
- `MYSQL_INCLUDE_DIR` / `MYSQL_LIBRARY` point at `mariadb-connector-c` manually.
- Database password for dbUser is set via `mysql_native_password` because the script expects pw auth. Default behavior is unix socket auth.

## License

TODO