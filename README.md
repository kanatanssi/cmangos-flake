# cmangos-flake

NixOS module and package for a CMaNGOS Classic server: MariaDB setup, PlayerBots, AHBot, declarative game accounts. x86_64-linux only.

Status: early. Tested in the bundled test VM with a client connecting. Not affiliated with the CMaNGOS project.

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
            realmAddress = "192.168.1.10"; # address clients use to reach this host, see Networking
            dbPasswordFile = config.sops.secrets.cmangos-db.path;
            gameAccounts = {
              perttupeikko = { passwordFile = config.sops.secrets.perttu.path; gmLevel = 0; };
              hilmahaltia = { passwordFile = config.sops.secrets.hilma.path; gmLevel = 2; };
            };
          };
        })
      ];
    };
  };
}
```

The package is built with this flake's own pinned nixpkgs, which is what it's tested against. You can add `inputs.cmangos.inputs.nixpkgs.follows = "nixpkgs";` to build against yours instead, but that combination is untested. There's no binary cache either way, so the first deploy compiles the server from source.

## Client data

Bring your own! Extract `maps`, `vmaps`, `mmaps` and `dbc` from your client into `cmangosDataDir`, defaults to `/var/lib/cmangos/data`. Cmangos-classic accepts the following client versions 1.12.1, 1.12.2 and 1.12.3 (builds 5875, 6005, 6141) (see [classic-db](https://github.com/cmangos/classic-db/blob/ec4f596146be6467ea93c57397858e329e2db852/README.md?plain=1#L3-L4) for the db and for mangosd `EXPECTED_MANGOSD_CLIENT_BUILD` defined in [SharedDefines.h](https://github.com/cmangos/mangos-classic/blob/8ec338a1704e7dcb1c0213eb7ed58f9231ade40f/src/game/Globals/SharedDefines.h#L2005))

The package ships upstream's extractors under `bin/tools`. With `a`, the script extracts everything without asking; the output directory has to exist:

```
nix build github:kanatanssi/cmangos-flake
mkdir -p /path/to/output
./result/bin/tools/ExtractResources.sh a /path/to/client /path/to/output
```

Then copy the resulting directories into `cmangosDataDir`. The mmaps step takes a long time.

## Options

| Option | Default | Notes |
|---|---|---|
| `enable` | `false` | |
| `dbPasswordFile` | required | Path to a file with the DB password. Letters A-Z a-z, digits 0-9, `-` and `_`. |
| `gameAccounts` | `{}` | See [Game accounts](#game-accounts). |
| `realmAddress` | `127.0.0.1` | Address realmd hands to clients for the world server. See [Networking](#networking). |
| `realmdPort` / `mangosdPort` | `3724` / `8085` | |
| `openPorts` | `false` | Opens `realmdPort` and `mangosdPort` (TCP). |
| `mangosdSettings` | `{}` | `mangosd.conf` overrides, see [Server config](#server-config). |
| `realmdSettings` | `{}` | `realmd.conf` overrides. |
| `playerbotSettings` | `{}` | `aiplayerbot.conf` overrides. |
| `ahbotSettings` | `{}` | `ahbot.conf` overrides. |
| `anticheatSettings` | `{}` | `anticheat.conf` overrides. |
| `cmangosDataDir` | `/var/lib/cmangos/data` | Extracted client data. Read-only for the service. |
| `cmangosWorkingDir` | `/var/lib/cmangos` | Holds `etc/` and `workingDir/`. cmangos finds its confs relative to the working dir, so they must stay parallel. |
| `user` | `cmangos` | System user running the daemons. |

## Networking

realmd advertises `realmAddress` and `mangosdPort` to clients as the world server's address, so it has to be reachable by the clients. `realmAddress` can be at most 32 characters: letters, digits, `.` and `-`.

The client's `realmlist.wtf` needs to point to realmd's address (and port, if not the default 3724).

## Secrets

All passwords are read from files at service start and never enter the Nix store. Use sops-nix or similar.

- DB password: letters A-Z a-z, digits 0-9, `-` and `_`.
- Game account passwords: 3-16 characters, letters A-Z a-z, digits 0-9, `-` and `_`.

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

`mangosd.conf`, `realmd.conf`, `aiplayerbot.conf`, `ahbot.conf` and `anticheat.conf` use the upstream `.dist` files as a baseline. You override them with env vars through the module's settings. The env var name is the prefix plus the full key, with dots replaced by underscores: `AiPlayerbot.MinRandomBots` becomes `PlayerBots_AiPlayerbot_MinRandomBots`. E.g.:

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
| **anticheat.conf** | Anticheat_ | [anticheat.conf.dist.in](https://github.com/cmangos/mangos-classic/blob/master/src/game/Anticheat/module/anticheat.conf.dist.in) |

The stock `anticheat.conf` has the anticheat and Warden **on**. Some clients, e.g. Wenilla, need both off:

```nix
services.cmangos-server.anticheatSettings = {
  Anticheat_Enable = "0";
  Anticheat_Warden_Enable = "0";
};
```


You can verify the prefixes in the repos. The mangosd, realmd and anticheat confs state the prefix in their header. For playerbots and the AH bot, it's in the code that loads the config:
- [PlayerbotAIConfig.cpp](https://github.com/cmangos/playerbots/blob/master/playerbot/PlayerbotAIConfig.cpp)
- [AhBotConfig.cpp](https://github.com/cmangos/playerbots/blob/master/ahbot/AhBotConfig.cpp)

### Memory and bot count

Random bots are full player objects inside mangosd, so memory use grows with the bot count. The stock `aiplayerbot.conf` logs in 1000 of them (`MinRandomBots` / `MaxRandomBots`), which will not fit on a small machine. Lower the count with `playerbotSettings`, and optionally cap mangosd's memory with a plain systemd override:

```nix
services.cmangos-server.playerbotSettings = {
  PlayerBots_AiPlayerbot_MinRandomBots = "200";
  PlayerBots_AiPlayerbot_MaxRandomBots = "200";
};

systemd.services.cmangos-mangosd.serviceConfig = {
  MemoryHigh = "5G"; # soft limit: the kernel starts reclaiming and throttling here
  MemoryMax = "6G";  # hard limit: only mangosd gets OOM-killed, not MariaDB or the rest of the system
};
```

The limit does not make bots cheaper. If mangosd hits `MemoryMax`, it gets killed and restarted with the same bot count, so size the bot count to the machine first. Check actual usage with `systemctl status cmangos-mangosd` or `systemd-cgtop`.

## Database

The module enables `services.mysql` with `pkgs.mariadb` and creates the four `classic*` databases and the `mangos` DB user in it. If the host already runs MySQL or MariaDB through `services.mysql`, the cmangos databases end up in that same instance, and the package must be MariaDB.

On first start, `cmangos-db-init.service` runs upstream's `InstallFullDB.sh -InstallAll` non-interactively. It creates the base structures and imports world content and the PlayerBots SQL.

The script needs MariaDB root and always connects over TCP, where root's default unix socket auth doesn't work. For the duration of the install, root gets a random temporary password next to its socket auth. Afterwards, root's original auth is restored, also when the install fails.

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

## First start and troubleshooting

On the first deploy, expect:
- a long build, since the server compiles from source
- `cmangos-db-init` to take several minutes while it imports the world database
- `cmangos-mangosd` to keep failing and restarting until the client data is in `cmangosDataDir`

The services, in start order:

| Service | What it does |
| :--- | :--- |
| `cmangos-db-init` | DB install on first start, DB user auth and realmlist on every start |
| `cmangos-accounts` | declarative game accounts, only exists if `gameAccounts` is set |
| `cmangos-realmd` | login server |
| `cmangos-mangosd` | world server |

Check each with `systemctl status <service>` and `journalctl -u <service>`. The daemons also write `Server.log` and `Realmd.log` to `cmangosWorkingDir/workingDir`, i.e. `/var/lib/cmangos/workingDir` by default.


## Game accounts

You can define game accounts in the module's settings. E.g.:

```nix
services.cmangos-server.gameAccounts = {
  perttupeikko = { passwordFile = "/run/secrets/perttupeikko"; gmLevel = 0; };
  hilmahaltia = { passwordFile = "/run/secrets/hilmahaltia"; gmLevel = 2; };
};
```

`cmangos-accounts.service` runs on every boot and whenever `gameAccounts` changes. It starts a temporary mangosd on world port 9999 (so that port must be free), and ensures each account in `gameAccounts` exists, its password matches the password set in the password file, and its GM level matches the config (0 player, 1 mod, 2 dm, 3 admin).

Changing `gameAccounts` on a running server restarts mangosd, so connected players get disconnected. The accounts service has to start a temporary mangosd, and it must not run next to the real one.

Accounts are only ensured to exist, never deleted. Removing one from the config leaves it in the database; delete it manually. Names and passwords: 3 to 16 characters, alphanumeric, dash - or underscore _.

`gameAccounts` is the way to add accounts. The server console is off (`Console.Enable = 0`) because mangosd runs as a systemd service, and upstream only allows `account create`, `account delete` and `account set password` from the console, not in game, whatever the GM level. A player can change their own password in game with `.account password`, but for accounts in `gameAccounts` the next run of `cmangos-accounts` sets it back to the one in the password file.

## Updating

If your server is running, it is probably best to just let it run. This flake does not offer automatic database migration, and a newer core can expect a newer schema and break things.

`nix flake update` moves the core, classic-db and playerbots to their latest commits, but `cmangos-db-init` only installs into empty databases. It never applies new SQL to an existing install, so after an update the core can run against an outdated schema. Keep the inputs pinned unless you plan to migrate. To migrate, back up first, then apply the updates with upstream's tools: classic-db's `InstallFullDB.sh` has `-UpdateCore` for the core's `sql/updates` and `-World` to reinstall the world DB (see its `-?` help).

Backups are not part of the module. NixOS's built-in MariaDB backup service covers it:

```nix
services.mysqlBackup = {
  enable = true;
  databases = [ "classicmangos" "classiccharacters" "classicrealmd" "classiclogs" ];
};
```

## Development

Core, classic-db and playerbots inputs all just point to the main branches, but the flake.lock has them pinned to specific commits.

Run test vm with:

```
nix build .#nixosConfigurations.testVM.config.system.build.vm
./result/bin/run-nixos-vm -nographic
```

The vm autologins as root. Its disk is the `.qcow2` in the directory you launch from; delete it for a clean database. The host's `/var/lib/cmangos/data` is shared into the VM, so put client data there.

The VM forwards ports 3724 and 8085 from the host, so a client on the host connects to `127.0.0.1`. The test config caps random bots at 50 and turns the anticheat and Warden off.

### Updating the flake inputs

nixpkgs follows a stable NixOS release (`nixos-26.05`) and is bumped by hand when a new release comes out, i.e. every May and November. The old release stops getting updates about a month after the new one.

Within a release, for security fixes:

```
nix flake update nixpkgs
```

For a new NixOS release, change the branch in `inputs.nixpkgs.url` in `flake.nix`, e.g. `nixos-26.05` to `nixos-26.11`, then:

```
nix flake update nixpkgs
```

To update cmangos itself, update all three together, so the core, playerbots and the DB match. See [Updating](#updating) for what this means for a running server.

```
nix flake update cmangos-classic cmangos-playerbots classic-db
```

Then update the two source links in [Client data](#client-data) to the new revs (`nix flake metadata` lists them) and check that the client builds haven't changed.

After any update, check and test before pushing:

```
nix flake check --no-build
rm -f nixos.qcow2   # fresh DB, so the install runs from scratch
nix build .#nixosConfigurations.testVM.config.system.build.vm
./result/bin/run-nixos-vm -nographic
```

Then connect with a client and check that the server, the bots and the accounts work.

## Build notes

- Boost: `Boost_USE_STATIC_LIBS` forced off, nixpkgs ships shared libraries.
- `FETCHCONTENT_FULLY_DISCONNECTED=ON`, cmake otherwise tries to pull zlib and Playerbots, instead...
- nixpkgs zlib is used and PlayerBots is added as an input and placed in cmangos' `src/modules/PlayerBots`
- `MYSQL_INCLUDE_DIR` / `MYSQL_LIBRARY` point at `mariadb-connector-c` manually.
- The DB user (`mangos`) gets `mysql_native_password` auth because the daemons and `InstallFullDB.sh` log in with a password. NixOS's default for `ensureUsers` is unix socket auth.

## License

The Nix code in this repository is licensed under the [MIT License](LICENSE).

This flake only fetches and builds upstream projects. Their code is not part of this repository and keeps its own license:

- [mangos-classic](https://github.com/cmangos/mangos-classic): GPL-2.0
- [classic-db](https://github.com/cmangos/classic-db): GPL-3.0
- [playerbots](https://github.com/cmangos/playerbots): GPL-2.0-or-later (per file headers)

Built server binaries are covered by the upstream licenses. Game client data is not included and remains the property of its owners.