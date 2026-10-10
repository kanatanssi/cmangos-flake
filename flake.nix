{
  description = "A Nix flake for running a CMaNGOS Classic Server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    cmangos-classic = { url = "github:cmangos/mangos-classic"; flake = false; };
    classic-db = { url = "github:cmangos/classic-db"; flake = false; };
    cmangos-playerbots = { url = "github:cmangos/playerbots"; flake = false; };
  };

  outputs = { self, nixpkgs, cmangos-classic, classic-db, cmangos-playerbots }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };

    # mangos-classic source with the playerbots module in place under src/modules/PlayerBots.
    # used as the build source (otherwise cmake tries to download playerbots and fails)
    # and as CORE_PATH for InstallFullDB.sh, so both see the same core + module revision
    cmangosSrc = pkgs.runCommand "cmangos-classic-src" {} ''
      cp -r --no-preserve=mode ${cmangos-classic} $out
      mkdir -p $out/src/modules
      cp -r --no-preserve=mode ${cmangos-playerbots} $out/src/modules/PlayerBots
    '';
  in {
    # build the cmangos server package
    packages.${system} = {
      default = pkgs.stdenv.mkDerivation {
        pname = "cmangos-classic";
        # nixpkgs convention for untagged sources, the exact commit is pinned in flake.lock
        version = let d = cmangos-classic.lastModifiedDate; in
          "0-unstable-${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";

        src = cmangosSrc;

        nativeBuildInputs = with pkgs; [ cmake pkg-config ];
        buildInputs = with pkgs; [ boost mariadb-connector-c ];

        hardeningDisable = [ "format" ];

        # cmangos defaults to searching for static boost libraries
        # nixos provides shared/dynamic libraries by default in 'pkgs.boost'.
        # hack CMakeLists.txt to force dynamic linking, otherwise build fails due to not finding boost
        preConfigure = ''
          substituteInPlace CMakeLists.txt \
            --replace-fail "set(Boost_USE_STATIC_LIBS ON)" "set(Boost_USE_STATIC_LIBS OFF)"
        '';

        # bypass cmangos internal FetchContent for zlib
        # forcing 'if(FALSE)' routes cmake straight to the else() block where it uses predefined nix zlib flags
        postPatch = ''
          sed -i 's/if (NOT ZLIB_FOUND.*/if (FALSE)/' dep/src/CMakeLists.txt
        '';

        cmakeFlags = [
          "-DPCH=1"
          "-DDEBUG=0"
          "-DBUILD_PLAYERBOTS=ON"
          # playerbots module ahbot is used instead of the core one, see README
          "-DBUILD_AHBOT=OFF"
          "-DBUILD_EXTRACTORS=ON"
          "-DCMAKE_INSTALL_PREFIX=${placeholder "out"}"
          # point to nixos-provided mariadb connector paths, cmake won't find mariadb otherwise
          "-DMYSQL_INCLUDE_DIR=${pkgs.lib.getDev pkgs.mariadb-connector-c}/include/mariadb"
          "-DMYSQL_LIBRARY=${pkgs.lib.getLib pkgs.mariadb-connector-c}/lib/mariadb/libmariadb.so"
          # tell cmake not attempt to pull deps from online
          "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
          # give exact header and library paths for zlib, cmake won't find zlib otherwise
          "-DZLIB_INCLUDE_DIRS=${pkgs.zlib.dev}/include"
          "-DZLIB_LIBRARIES=${pkgs.zlib}/lib/libz.so"
        ];
      };
    };

    nixosModules.default = { config, pkgs, lib, ... }:
    let
      cfg = config.services.cmangos-server;
      # this is just an alias, since the pkgs ref is really long otherwise
      pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.default;

      # dbUser written as a constant here, can be made into an option later
      dbUser = "mangos";

      # account names, account passwords and the db password allowed chars
      allowedCharset = "[A-Za-z0-9_-]";
      # allowed min and max lengths for game accounts and their passwords
      allowedLength = "{3,16}";

      accountRegex = "^${allowedCharset}${allowedLength}$";
      dbPasswordRegex = "^${allowedCharset}+$";

      # check secret file's content against a regex.
      # always capture the output with ${...}, calling bare prints the secret!
      # error prints the file path
      secretReader = ''
        readSecret() {
          local value
          value=$(< "$1")
          if ! [[ "$value" =~ $2 ]]; then
            echo "$1 does not match $2" >&2
            return 1
          fi
          printf '%s' "$value"
        }
      '';

      # read the db password from the given file at runtime and export the mangosd db connection strings
      # this is done to avoid putting the db password inside the nix store
      # this script is up here because it is used by both the cmangos-accounts and cmangos-mangosd services
      mangosdDbEnv = pwPath: ''
        pw=$(< "${pwPath}")
        export Mangosd_LoginDatabaseInfo="127.0.0.1;3306;${dbUser};$pw;classicrealmd"
        export Mangosd_WorldDatabaseInfo="127.0.0.1;3306;${dbUser};$pw;classicmangos"
        export Mangosd_CharacterDatabaseInfo="127.0.0.1;3306;${dbUser};$pw;classiccharacters"
        export Mangosd_LogsDatabaseInfo="127.0.0.1;3306;${dbUser};$pw;classiclogs"
      '';
    in {
      options.services.cmangos-server = {
        enable = lib.mkEnableOption "CMaNGOS Classic Server";

        user = lib.mkOption {
          type = lib.types.str;
          default = "cmangos";
          description = "Unprivileged system user to run the CMaNGOS daemons.";
        };

        dbPasswordFile = lib.mkOption {
          type = lib.types.str;
          description = "Absolute path to a file containing the db password. Password can only contain alphanumerics Aa-Zz 0-9, - and _.";
        };

        cmangosDataDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/cmangos/data";
          description = "Location of map data extracted from game client. Is set to read only.";
        };

        cmangosWorkingDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/cmangos";
          description = "Working dir for the server. Conf is placed under this because of the way cmangos looks for conf files";
        };

        realmAddress = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1";
          example = "example.com";
          description = "Realmd advertises this mangosd address to the users.";
        };

        realmdPort = lib.mkOption {
          type = lib.types.port;
          default = 3724;
          description = "Port for login server.";
        };

        mangosdPort = lib.mkOption {
          type = lib.types.port;
          default = 8085;
          description = "Port for the world server.";
        };

        openPorts = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open ports in the firewall for realmd and mangosd.";
        };

        mangosdSettings = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          example = { Mangosd_PlayerLimit = "50"; Mangosd_Rate_XP_Kill = "2"; };
          description = "Any mangosd.conf key; passed as Mangosd_* env vars. Check mangosd.conf.dist from repo for available keys";
        };

        realmdSettings = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          example = { Realmd_RealmsStateUpdateDelay = "20"; Realmd_WrongPass_MaxCount = "0"; };
          description = "Any realmd.conf key; passed as Realmd_* env vars. Check realmd.conf.dist from repo for available keys";
        };

        playerbotSettings = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          example = { PlayerBots_AiPlayerbot_MinRandomBots = "1000"; PlayerBots_AiPlayerbot_ClassRaceProb_8_0 = "1000"; };
          description = "Any aiplayerbot.conf key passed as PlayerBots_AiPlayerbot_* env vars. Check aiplayerbot.conf.dist from repo for available keys";
        };

        ahbotSettings = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          example = { AHBot_AhBot_MaxItemLevel = "500"; AHBot_AhBot_MaxAuctionCount_equip_white = "500"; };
          description = "Any ahbot.conf key; passed as AHBot_AhBot_* env vars. Check ahbot.conf.dist from repo for available keys";
        };

        anticheatSettings = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          example = { Anticheat_Enable = "0"; Anticheat_Warden_Enable = "0"; };
          description = "Any anticheat.conf key; passed as Anticheat_* env vars. The stock conf has anticheat and Warden on; some clients need both off. Check anticheat.conf.dist from repo for available keys";
        };

        gameAccounts = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options = {
              passwordFile = lib.mkOption {
                type = lib.types.str;
                description = "Absolute path to a file containing the account password. Password can be 3-16 characters long and contain alphanumerics Aa-Zz 0-9, - and _.";
              };
              gmLevel = lib.mkOption {
                type = lib.types.ints.between 0 3;
                default = 0;
                description = "0 for player, 1 for mod, 2 for dm, 3 for admin.";
              };
            };
          });
          default = {};
          example = {
            perttupeikko = { passwordFile = "/run/secrets/perttupeikko"; gmLevel = 0; };
            hilmahaltia = { passwordFile = "/run/secrets/hilmahaltia"; gmLevel = 2; };
          };
          description = "Map of game accounts to create. Account name can be 3-16 characters long and contain alphanumerics Aa-Zz 0-9, - and _.";
        };
      };

      config = lib.mkIf cfg.enable {

        # check if game account names are valid
        assertions = lib.mapAttrsToList (name: _: {
          assertion = builtins.match "${allowedCharset}${allowedLength}" name != null;
          message = "CMaNGOS account name '${name}' must be 3-16 characters: letters, digits, '-' and '_'.";
        }) cfg.gameAccounts ++ [{
          assertion = lib.all
            (f: lib.hasPrefix "/" f && !lib.hasPrefix "${builtins.storeDir}/" f)
            ([ cfg.dbPasswordFile ] ++ lib.mapAttrsToList (_: a: a.passwordFile) cfg.gameAccounts);
          message = "CMaNGOS password files must be absolute paths outside the nix store (use sops-nix or similar).";
        } {
          # realmAddress goes into sql as is, and the realmlist address column is varchar(32)
          assertion = builtins.match "[A-Za-z0-9.-]+" cfg.realmAddress != null && lib.stringLength cfg.realmAddress <= 32;
          message = "CMaNGOS realmAddress must be a hostname or IP of at most 32 characters.";
        }];

        # add system account for running the service
        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.user;
          description = "CMaNGOS daemon user";
        };
        users.groups.${cfg.user} = {};

        # open firewall ports if openPorts is true
        networking.firewall = lib.mkIf cfg.openPorts {
          allowedTCPPorts = [ cfg.realmdPort cfg.mangosdPort ];
        };

        # ensure necessary directories exist and cfg.user can access before services are run.
        # cmangos looks for confs in fun and interesting ways, so workingdir and conf dir should be parallel!
        systemd.tmpfiles.rules = [
          "d ${cfg.cmangosDataDir} 0550 ${cfg.user} ${cfg.user} -"
          "d ${cfg.cmangosWorkingDir}/workingDir 0750 ${cfg.user} ${cfg.user} -"
          "d ${cfg.cmangosWorkingDir}/etc 0750 ${cfg.user} ${cfg.user} -"
          "L+ ${cfg.cmangosWorkingDir}/etc/mangosd.conf - - - - ${cmangos-classic}/src/mangosd/mangosd.conf.dist.in"
          "L+ ${cfg.cmangosWorkingDir}/etc/realmd.conf - - - - ${cmangos-classic}/src/realmd/realmd.conf.dist.in"
          "L+ ${cfg.cmangosWorkingDir}/etc/aiplayerbot.conf - - - - ${cmangos-playerbots}/playerbot/aiplayerbot.conf.dist.in"
          "L+ ${cfg.cmangosWorkingDir}/etc/ahbot.conf - - - - ${cmangos-playerbots}/ahbot/ahbot.conf.dist.in"
          "L+ ${cfg.cmangosWorkingDir}/etc/anticheat.conf - - - - ${pkg}/etc/anticheat.conf.dist"
          # Warden.ModuleDir defaults to warden_modules, relative to the working dir
          "L+ ${cfg.cmangosWorkingDir}/workingDir/warden_modules - - - - ${pkg}/bin/warden_modules"
        ];

        # db service. dbUser is granted all privileges to the cmangos related dbs
        services.mysql = {
          enable = true;
          package = pkgs.mariadb;
          ensureDatabases = [ "classicmangos" "classiccharacters" "classicrealmd" "classiclogs" ];
          ensureUsers = [
            {
              name = dbUser;
              ensurePermissions = {
                "classicmangos.*" = "ALL PRIVILEGES";
                "classiccharacters.*" = "ALL PRIVILEGES";
                "classicrealmd.*" = "ALL PRIVILEGES";
                "classiclogs.*" = "ALL PRIVILEGES";
              };
            }
          ];
        };

        # set up dbs on first run with the InstallFullDB.sh script and config from above
        # the script applies base structures + content from classic-db + playerbots
        systemd.services.cmangos-db-init =
          let
            # no secrets in here, the password is read from file when the script sources this
            installConfig = pkgs.writeText "InstallFullDB.config" ''
              MYSQL_HOST="localhost"
              MYSQL_PORT="3306"
              MYSQL_USERNAME="${dbUser}"
              # the below gets expanded by the bash script
              MYSQL_PASSWORD="$(cat ${cfg.dbPasswordFile})"
              MYSQL_PATH="${pkgs.mariadb}/bin/mariadb"
              MYSQL_DUMP_PATH="${pkgs.mariadb}/bin/mariadb-dump"

              # target db
              WORLD_DB_NAME="classicmangos"

              # point to mangos-classic source, with playerbots module under src/modules
              CORE_PATH="${cmangosSrc}"

              # optional, YES/NO
              # PLAYERBOTS_DB="YES"
              # AHBOT="YES"

              # Skip 10-second warning
              FORCE_WAIT="NO"
            '';
          in {
          description = "Initialize CMaNGOS Classic from classic-db repo";
          after = [ "mysql.service" ];
          requires = [ "mysql.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = true;

          # ncurses package here for clear
          path = with pkgs; [ mariadb gzip bash python3 ncurses ];

          script = ''
            set -euo pipefail

            ${secretReader}

            until mariadb-admin ping -u root --silent; do
              sleep 1
            done

            echo "Configuring traditional password authentication for ${dbUser}..."
            # charset is restricted by the regex, so the password is safe to put inside the sql quotes
            dbpw=$(readSecret ${lib.escapeShellArg cfg.dbPasswordFile} '${dbPasswordRegex}')
            mariadb -u root <<< "ALTER USER '${dbUser}'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('$dbpw'); FLUSH PRIVILEGES;"

            # only install if none of the cmangos dbs has any tables, -InstallAll drops and recreates them.
            # a failed install is not retried, drop the dbs manually to reinstall
            if [ $(mariadb -u root -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ('classicmangos','classiccharacters','classicrealmd','classiclogs')") -eq 0 ]; then
              echo "CMaNGOS dbs empty. Running full install..."

              echo "Create temp workspace..."
              WORK_DIR=$(mktemp -d)

              cp -r ${classic-db}/* $WORK_DIR/

              echo "Drop in configuration file..."
              cp ${installConfig} $WORK_DIR/InstallFullDB.config

              cd $WORK_DIR

              # InstallFullDB.sh connects over tcp (-h -P), where the default unix socket auth does not work
              # give root a temporary random password for the duration of the install
              # trap restores it on any exit, also when install fails
              origRootAuth=$(mariadb -u root -Nse "SHOW CREATE USER 'root'@'localhost'")
              rootpw=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
              restoreRootAuth() { mariadb -u root <<< "''${origRootAuth/CREATE USER/ALTER USER}; FLUSH PRIVILEGES;"; }
              trap restoreRootAuth EXIT
              mariadb -u root <<< "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$rootpw'); FLUSH PRIVILEGES;"

              # dbs are empty, so dropping and recreating them loses nothing.
              # applies base structures, world content and playerbots sql
              echo "Running InstallFullDB.sh"
              bash ./InstallFullDB.sh -InstallAll root "$rootpw" DeleteAll

              echo "Deleting scratch workspace..."
              cd /
              rm -rf $WORK_DIR
              echo "CMaNGOS database initialization complete!"
            else
              echo "CMaNGOS databases already populated. Skipping initialization."
            fi

            # realmd hands this address and port to clients, keep it in sync with conf
            echo "Ensuring realmlist matches conf..."
            mariadb -u root classicrealmd <<< "UPDATE realmlist SET address='${cfg.realmAddress}', port=${toString cfg.mangosdPort} WHERE id=1;"
          '';
        };

        # service only gets created if gameAccounts is not empty
        systemd.services.cmangos-accounts = lib.mkIf (cfg.gameAccounts != {}) {
          description = "Create/update CMaNGOS declarative accounts via mangosd console";
          after = [ "mysql.service" "cmangos-db-init.service" ];
          requires = [ "cmangos-db-init.service" ];
          before = [ "cmangos-mangosd.service" "cmangos-realmd.service" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = cfg.user;
            Group = cfg.user;
            WorkingDirectory = "${cfg.cmangosWorkingDir}/workingDir";
            # private dir for the screen socket, systemd removes it
            RuntimeDirectory = "cmangos-accounts";
            RuntimeDirectoryMode = "0700";
            # secrets are exposed under $CREDENTIALS_DIRECTORY/<name>
            LoadCredential =
              [ "dbpass:${cfg.dbPasswordFile}" ]
              ++ lib.mapAttrsToList (account: opts: "acc-${account}:${opts.passwordFile}") cfg.gameAccounts;
          };

          path = with pkgs; [ mariadb screen coreutils gnugrep ];

          # the script spins up a temporary cmangos instance with screen
          # and then loops over the game accounts and run the commands to add players.
          # done this way as usually the server console is interactive
          script = ''
            set -euo pipefail

            ${secretReader}

            # private dir from RuntimeDirectory, removed by systemd when the service stops
            export SCREENDIR="$RUNTIME_DIRECTORY/screen"
            mkdir -m 700 "$SCREENDIR"

            # temp instance: same conf and dbs as the real server, but console on and a private port
            ${mangosdDbEnv "$CREDENTIALS_DIRECTORY/dbpass"}
            # lets the mariadb client authenticate as dbUser without a password on the command line
            export MYSQL_PWD=$pw
            export Mangosd_DataDir=${lib.escapeShellArg cfg.cmangosDataDir}
            export Mangosd_Console_Enable=1
            export Mangosd_WorldServerPort=9999
            export PlayerBots_AiPlayerbot_Enabled=0
            export AHBot_AhBot_Enabled=0
            # fresh Server.log for the readiness check, also keeps temp logs out of workingDir
            export Mangosd_LogsDir="$RUNTIME_DIRECTORY"

            # printf is a bash builtin, so the command (and password) never shows up in any process' argv
            consoleCmd() {
              printf '%s\n' "$1" > "$RUNTIME_DIRECTORY/cmd"
              screen -S mangos_init -X readbuf "$RUNTIME_DIRECTORY/cmd"
              screen -S mangos_init -X paste .
              rm -f "$RUNTIME_DIRECTORY/cmd"
            }

            serverRunning() { [[ "$(screen -ls || true)" == *mangos_init* ]]; }

            echo "Starting temporary mangosd instance in screen to process accounts..."
            screen -dmS mangos_init ${pkg}/bin/mangosd -c ${cfg.cmangosWorkingDir}/etc/mangosd.conf

            echo "Waiting for the world to load..."
            for _ in $(seq 1 300); do
              grep -q "World initialized" "$RUNTIME_DIRECTORY/Server.log" 2>/dev/null && break
              if ! serverRunning; then
                echo "Temporary server exited during startup:" >&2
                tail -n 20 "$RUNTIME_DIRECTORY/Server.log" >&2 || true
                exit 1
              fi
              sleep 1
            done
            grep -q "World initialized" "$RUNTIME_DIRECTORY/Server.log" || { echo "Temporary server did not start in time" >&2; exit 1; }

            echo "Processing accounts..."
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (user: opts: ''
              accpw=$(readSecret "$CREDENTIALS_DIRECTORY/acc-${user}" '${accountRegex}')
              EXISTS=$(mariadb -u ${dbUser} classicrealmd -Nse "SELECT COUNT(*) FROM account WHERE username='${lib.strings.toUpper user}';")

              if [ "$EXISTS" -eq 0 ]; then
                echo "Creating new account: ${user}"
                consoleCmd "account create ${user} $accpw"
              else
                echo "Account ${user} exists. Ensuring password matches conf..."
                consoleCmd "account set password ${user} $accpw $accpw"
              fi
              sleep 1
            '') cfg.gameAccounts)}

            echo "Stopping temporary server instance..."
            consoleCmd "server exit"

            for _ in $(seq 1 300); do
              serverRunning || break
              sleep 1
            done
            if serverRunning; then
              echo "Temporary server did not exit in time" >&2
              exit 1
            fi

            echo "Setting GM levels..."
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (user: opts: ''
              mariadb -u ${dbUser} classicrealmd -e "UPDATE account SET gmlevel=${toString opts.gmLevel} WHERE username='${lib.strings.toUpper user}';"
            '') cfg.gameAccounts)}

            echo "All declarative accounts processed!"
          '';
        };

        # login server, runs as cfg.user
        systemd.services.cmangos-realmd =
          let
            # the start script here is different from mangosd, as mangosd exports env vars with Mangosd_*, realmd wants Realmd_*
            realmdStart = pkgs.writeShellScript "realmd-start" ''
              pw=$(< "$CREDENTIALS_DIRECTORY/dbpass")
              export Realmd_LoginDatabaseInfo="127.0.0.1;3306;${dbUser};$pw;classicrealmd"
              exec ${pkg}/bin/realmd -c ${cfg.cmangosWorkingDir}/etc/realmd.conf
            '';
          in {
          description = "CMaNGOS Classic Logon Daemon";
          after = [ "network.target" "cmangos-db-init.service" ];
          requires = [ "cmangos-db-init.service" ];
          wantedBy = [ "multi-user.target" ];

          environment = {
            Realmd_RealmServerPort = toString cfg.realmdPort;
          } // cfg.realmdSettings;

          serviceConfig = {
            # pass the secret file to the service/user under $CREDENTIALS_DIRECTORY/dbpass
            LoadCredential = "dbpass:${cfg.dbPasswordFile}";
            ExecStart = realmdStart;
            WorkingDirectory = "${cfg.cmangosWorkingDir}/workingDir";
            User = cfg.user;
            Group = cfg.user;
            Restart = "always";
            # without a delay, a few quick failures (e.g. db not up yet) hit systemd's start limit
            RestartSec = 5;
          };
        };

        # world server, runs as cfg.user
        systemd.services.cmangos-mangosd =
          let
            # read the db password from file at service start, other config env overrides below
            mangosdStart = pkgs.writeShellScript "mangosd-start" ''
              ${mangosdDbEnv "$CREDENTIALS_DIRECTORY/dbpass"}
              exec ${pkg}/bin/mangosd -c ${cfg.cmangosWorkingDir}/etc/mangosd.conf
            '';
          in {
            description = "CMaNGOS Classic World Daemon";
            after = [ "network.target" "cmangos-db-init.service" ];
            # requiring the accounts service makes a rerun of it (e.g. gameAccounts changed) stop mangosd first,
            # so its temporary instance never runs next to this one. That instance marks the realm offline on exit.
            requires = [ "cmangos-db-init.service" ]
              ++ lib.optional (cfg.gameAccounts != {}) "cmangos-accounts.service";
            wantedBy = [ "multi-user.target" ];

            # env vars from conf
            environment = {
              Mangosd_DataDir = cfg.cmangosDataDir;
              Mangosd_WorldServerPort = toString cfg.mangosdPort;
              Mangosd_Console_Enable = "0";
            } // cfg.mangosdSettings // cfg.playerbotSettings // cfg.ahbotSettings // cfg.anticheatSettings;

            serviceConfig = {
              # pass the secret file to the service/user under $CREDENTIALS_DIRECTORY/dbpass
              LoadCredential = "dbpass:${cfg.dbPasswordFile}";
              ExecStart = mangosdStart;
              WorkingDirectory = "${cfg.cmangosWorkingDir}/workingDir";
              User = cfg.user;
              Group = cfg.user;
              Restart = "always";
              RestartSec = 5;
              # mangosd stops cleanly on SIGTERM and systemd waits until it exits, this is only the upper bound
              # before SIGKILL. The default 90s can be too short to save many bots and players
              TimeoutStopSec = 300;
            };
          };
      };
    };

    # vm for testing
    nixosConfigurations.testVM = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.default
        "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
        {
          services.cmangos-server = {
            enable = true;
            openPorts = true;
            dbPasswordFile = "/etc/cmangos-test/dbpass";
            gameAccounts = {
              perttupeikko = { passwordFile = "/etc/cmangos-test/perttupeikko"; gmLevel = 0; };
              hilmahaltia = { passwordFile = "/etc/cmangos-test/hilmahaltia"; gmLevel = 2; };
            };
            playerbotSettings = {
              PlayerBots_AiPlayerbot_MinRandomBots = "50";
              PlayerBots_AiPlayerbot_MaxRandomBots = "50";
            };
            # the stock anticheat.conf has both on, turn off for testing different clients
            anticheatSettings = {
              Anticheat_Enable = "0";
              Anticheat_Warden_Enable = "0";
            };
          };

          # test only! written like this, passwords end up in the nix store.
          # in real life use something like sops-nix to manage secrets
          environment.etc."cmangos-test/dbpass".text = "mangos";
          environment.etc."cmangos-test/perttupeikko".text = "password123";
          environment.etc."cmangos-test/hilmahaltia".text = "password456";

          system.stateVersion = "26.05";

          # set vm to autologin to root, this is just for when you run the test vm
          users.users.root.password = "root";
          services.getty.autologinUser = "root";

          # the defaults (1 GB ram, 1 GB disk) are too small for the world db + server
          virtualisation.memorySize = 8192;
          virtualisation.cores = 4;
          virtualisation.diskSize = 8192;

          virtualisation.forwardPorts = [
            { from = "host"; host.port = 3724; guest.port = 3724; }  # realmd auth
            { from = "host"; host.port = 8085; guest.port = 8085; }  # mangosd world
          ];

          # share /var/lib/cmangos/data with the vm for testing (for extracted client data)
          virtualisation.sharedDirectories = {
            cmangos-data = {
              source = "/var/lib/cmangos/data";
              target = "/var/lib/cmangos/data";
            };
          };
        }
      ];
    };
  };
}
