{
  description = "A Nix flake for running a CMaNGOS Classic WoW Server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    cmangos-src = {
      url = "github:cmangos/mangos-classic";
      flake = false;
    };

    classic-db = {
      url = "github:cmangos/classic-db";
      flake = false;
    };

    cmangos-playerbots = {
      url = "github:cmangos/playerbots/0b3e77f5dae92c2eb304288ed0d6c8139c3b7fdc";
      flake = false;
    };

    cmangos-zlib = {
      url = "github:madler/zlib/v1.3.1";
      flake = false;
    };
  };

  # build the cmangos server package
  outputs = { self, nixpkgs, cmangos-src, classic-db, cmangos-zlib, cmangos-playerbots }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
  in {
    packages.${system} = {
      default = pkgs.stdenv.mkDerivation {
        pname = "cmangos-classic";
        version = "date=${cmangos-src.lastModifiedDate or "unknown"}-${cmangos-src.shortRev or "dirty"}";

        src = cmangos-src;

        nativeBuildInputs = with pkgs; [ cmake gcc pkg-config ];
        buildInputs = with pkgs; [ boost mariadb-connector-c ];

        hardeningDisable = [ "format" ];

        # cmangos defaults to searching for static boost libraries
        # nixos provides shared/dynamic libraries by default in 'pkgs.boost'.
        # hack CMakeLists.txt to force dynamic linking, otherwise build fails due to not finding boost

        # manually move playerbots into the sandbox's source tree before configuration
        # otherwise cmake tries to download it and fails
        preConfigure = ''
          substituteInPlace CMakeLists.txt \
            --replace "set(Boost_USE_STATIC_LIBS ON)" "set(Boost_USE_STATIC_LIBS OFF)"

          mkdir -p src/modules
          cp -r ${cmangos-playerbots} src/modules/PlayerBots
          chmod -R +w src/modules/PlayerBots
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
          "-DBUILD_AHBOT=ON"
          "-DBUILD_EXTRACTORS=ON"
          "-DCMAKE_INSTALL_PREFIX=${placeholder "out"}"
          # point to nixos-provided mariadb connector paths, cmake won't find mariadb otherwise
          "-DMYSQL_INCLUDE_DIR=${pkgs.lib.getDev pkgs.mariadb-connector-c}/include/mariadb"
          "-DMYSQL_LIBRARY=${pkgs.lib.getLib pkgs.mariadb-connector-c}/lib/mariadb/libmariadb.so"
          # tell cmake not attempt to pull deps from online
          "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
          # give exact header and library paths for zlibm cmake won't find zlib otherwise
          "-DZLIB_INCLUDE_DIRS=${pkgs.zlib.dev}/include"
          "-DZLIB_LIBRARIES=${pkgs.zlib}/lib/libz.so"
        ];
      };
    };

    nixosModules.default = { config, pkgs, lib, ... }:
    let
      cfg = config.services.cmangos-server;

      # helper to make mangosd and realmd configs.
      # mangosdconfig allows overwriting configuration fields with environment variables
      # env vars start with Mangosd_, points . are replaced with underscores _
      # e.g. Rate.Health -> Mangosd_Rate_Health=1.2, DataDir -> Mangosd_DataDir=/tmp
      mkEnv = prefix: attrs: lib.mapAttrs' (k: v:
        lib.nameValuePair (prefix + lib.replaceStrings [ "." ] [ "_" ] k)
          (if lib.isBool v then (if v then "1" else "0") else toString v)
      ) attrs;
    in {
      options.services.cmangos-server = {
        enable = lib.mkEnableOption "CMaNGOS Classic Server";

        user = lib.mkOption {
          type = lib.types.str;
          default = "cmangos";
          description = "Unprivileged system user to run the CMaNGOS daemons.";
        };

        dbUser = lib.mkOption {
          type = lib.types.str;
          default = "mangos";
        };

        dbPasswordFile = lib.mkOption {
          type = lib.types.str;
          description = "Absolute path to a file containing the db password. Password must not contain a semicolon ';'";
        };

        cmangosDataDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/cmangos/data";
          description = "Location of map data extracted from Wow Classic client. Is set to read only.";
        };

        cmangosWorkingDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/cmangos";
          description = "Working dir for the server. Conf is placed under this because of the way cmangos looks for conf files";
        };

        realmdPort = lib.mkOption {
          type = lib.types.int;
          default = 3724;
          description = "Port for login server.";
        };

        mangosdPort = lib.mkOption {
          type = lib.types.int;
          default = 8085;
          description = "Port for the world server.";
        };

        openPorts = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open ports in the firewall for realmd and mangosd.";
        };

        realmAddress = lib.mkOption {
          type = lib.types.str;
          default = "example.com";
          description = "Realmd advertises this to clients. Should point to the world server and be reachable by client.";
        };

        mangosdSettings = lib.mkOption {
          type = with lib.types; attrsOf (oneOf [ str int float bool ]);
          default = {};
          example = { PlayerLimit = 50; "Rate.XP.Kill" = 2; };
          description = "Any mangosd.conf key; passed as Mangosd_* env vars. Check mangosd.conf.dist from repo for available keys";
        };

        realmdSettings = lib.mkOption {
          type = with lib.types; attrsOf (oneOf [ str int float bool ]);
          default = {};
          example = { RealmsStateUpdateDelay = 20; "WrongPass.MaxCount" = 0 };
          description = "Any realmd.conf key; passed as Realmd_* env vars. Check realmd.conf.dist from repo for available keys";
        };

        gameAccounts = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options = {
              password = lib.mkOption {
                type = lib.types.str;
                description = "Password for the account.";
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
            perttupeikko = { password = "password123"; gmLevel = 0; };
            hilmahaltia = { password = "password456"; gmLevel = 2; };
          };
          description = "Map of game accounts to create. Account name can only be 16 characters and contain alphanumerics Aa-Zz 0-9.";
        };
      };

      config = lib.mkIf cfg.enable {

        # check if game account names are valid
        assertions = lib.mapAttrsToList (name: value: {
          assertion = (builtins.match "[a-zA-Z0-9_]+" name) != null;
          message = "CMaNGOS account username '${name}' contains invalid characters! Only alphanumeric characters and underscores are allowed.";
        }) cfg.gameAccounts ++ lib.mapAttrsToList (name: value: {
          assertion = lib.stringLength name <= 16;
          message = "CMaNGOS account username '${name}' is too long! Maximum length is 16 characters.";
        }) cfg.gameAccounts;

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
          allowedUDPPorts = [ cfg.realmdPort cfg.mangosdPort ];
        };

        # ensure necessary directories exist and cfg.user can accesss before services are run.
        # cmangos looks for confs in fun and interesting ways, so workingdir and conf dir should be parallel!
        systemd.tmpfiles.rules = [
          "d ${cfg.cmangosDataDir} 0550 ${cfg.user} ${cfg.user} -"
          "d ${cfg.cmangosWorkingDir}/workingDir 0750 ${cfg.user} ${cfg.user} -"
          "d ${cfg.cmangosWorkingDir}/etc 0750 ${cfg.user} ${cfg.user} -"
          "L+ ${cfg.cmangosWorkingDir}/etc/aiplayerbot.conf - - - - /etc/cmangos/aiplayerbot.conf"
          "L+ ${cfg.cmangosWorkingDir}/etc/ahbot.conf - - - - /etc/cmangos/ahbot.conf"
          "L+ ${cfg.cmangosWorkingDir}/etc/mangosd.conf - - - - ${cmangos-src}/src/mangosd/mangosd.conf.dist.in"
          "L+ ${cfg.cmangosWorkingDir}/etc/realmd.conf - - - - ${cmangos-src}/src/realmd/realmd.conf.dist.in"
        ];

        # config files start from here.
        # conf for InstallFullDB.sh script
        # then aiplayerbot and auctionhousebot confs
        # mangosd and realmd configs go with their respective systemd service so as to not put db password in the nix store
        environment.etc = {
          "cmangos/InstallFullDB.config".text = ''
            # database connection
            MYSQL_HOST="localhost"
            MYSQL_PORT="3306"
            MYSQL_USERNAME="${cfg.dbUser}"
            # the below gets expanded by the bash script
            MYSQL_PASSWORD="$(cat ${cfg.dbPasswordFile})"
            MYSQL_PATH="mysql"
            MYSQL_DUMP_PATH="mysqldump"

            # target db
            WORLD_DB_NAME="classicmangos"

            # point to mangos-classic repo
            CORE_PATH="${cmangos-src}"

            # dptional, YES/NO
            PLAYERBOTS_DB="YES"
            AHBOT="YES"

            # Skip 10-second warning
            FORCE_WAIT="NO"
          '';

          "cmangos/aiplayerbot.conf".text = ''
            [AiPlayerbot]
            ConfVersion = 2024020101
            AiPlayerbot.Enabled = 1
            AiPlayerbot.RandomBotAutologin = 1
            AiPlayerbot.MinRandomBots = 10
            AiPlayerbot.MaxRandomBots = 30
            AiPlayerbot.RandomBotAccountPrefix = rndbot
            AiPlayerbot.RandomBotAccountCount = 50
            AiPlayerbot.DeleteRandomBots = 0

            AiPlayerbot.RandomBotJoinGuild = 1
            AiPlayerbot.ChatBotsEnabled = 1

            AiPlayerbot.BotCheats.Gathering = 1
            AiPlayerbot.AutoEquipUpgrade = 1
          '';

          "cmangos/ahbot.conf".text = ''
            [AhbotConf]
            ConfVersion = 2024020101

            AuctionHouseBot.Seller.Enabled = 1

            AuctionHouseBot.Buyer.Enabled = 1

            AuctionHouseBot.Chance.Sell = 30
            AuctionHouseBot.Chance.Buy = 20

            # min_item_level, max_item_level, max_auctions
            AuctionHouseBot.Loot.Commons = 1,60,1000
            AuctionHouseBot.Loot.Uncommons = 1,60,200
            AuctionHouseBot.Loot.Rares = 1,60,50
            AuctionHouseBot.Loot.Epics = 1,60,5
          '';
        };

        # db service. dbUser is granted all privileges to the cmangos related dbs
        services.mysql = {
          enable = true;
          package = pkgs.mariadb;
          ensureDatabases = [ "classicmangos" "classiccharacters" "classicrealmd" "classiclogs" ];
          ensureUsers = [
            {
              name = cfg.dbUser;
              ensurePermissions = {
                "classicmangos.*" = "ALL PRIVILEGES";
                "classiccharacters.*" = "ALL PRIVILEGES";
                "classicrealmd.*" = "ALL PRIVILEGES";
                "classiclogs.*" = "ALL PRIVILEGES";
              };
            }
          ];
        };

        # run the InstallFullDB.sh script with config from above
        systemd.services.cmangos-db-init = {
          description = "Initialize CMaNGOS Classic from classic-db repo";
          after = [ "mysql.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = true;

          # ncurses package here for clear
          path = with pkgs; [ mariadb gzip bash python3 ncurses ];

          script = let
            botSql = "${cmangos-playerbots}/sql";
          in ''

            set -euo pipefail

            until mariadb-admin ping -u root --silent; do
              sleep 1
            done

            echo "Configuring traditional password authentication for ${cfg.dbUser}..."
            dbpw=$(< ${lib.escapeShellArg cfg.dbPasswordFile})
            dbpw=''${dbpw//\\/\\\\}
            dbpw=''${dbpw//\'/\\\'}
            mariadb -u root <<< "ALTER USER '${cfg.dbUser}'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('$dbpw'); FLUSH PRIVILEGES;"


            if [ $(mariadb -u root -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='classicrealmd'") -eq 0 ]; then
              echo "CMaNGOS dbs empty. Initializing base structures..."

              echo "Applying core base structures..."
              mariadb -u root classicrealmd < ${cmangos-src}/sql/base/realmd.sql
              mariadb -u root classiccharacters < ${cmangos-src}/sql/base/characters.sql
              mariadb -u root classicmangos < ${cmangos-src}/sql/base/mangos.sql
              mariadb -u root classiclogs < ${cmangos-src}/sql/base/logs.sql

              echo "Create temp workspace..."
              WORK_DIR=$(mktemp -d)

              cp -r ${classic-db}/* $WORK_DIR/

              echo "Drop in configuration file from environment.etc..."
              cp /etc/cmangos/InstallFullDB.config $WORK_DIR/InstallFullDB.config

              ln -s $(which mariadb) $WORK_DIR/mysql
              ln -s $(which mariadb-dump) $WORK_DIR/mysqldump
              export PATH=$WORK_DIR:$PATH

              cd $WORK_DIR

              echo "Running InstallFullDB.sh"
              bash ./InstallFullDB.sh -World

              echo "Deleting scratch workspace..."
              cd /
              rm -rf $WORK_DIR

            else
              echo "CMaNGOS databases already populated. Skipping initialization."
            fi

            echo "Apply playerbots db changes..."
            applyBotSql() {
              local db="$1" dir="$2"

              if [ ! -d "$dir" ]; then
                echo "Playerbot SQL directory $dir not found" >&2
                exit 1
              fi

              local count
              count=$(mariadb -u root -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db' AND table_name LIKE 'ai\_playerbot%'")
              [ "$count" -eq 0 ] || return 0

              local files=()
              while IFS= read -r f; do files+=("$f"); done < <(
                find "$dir" -name '*.sql' -not -path '*/tbc/*' -not -path '*/wotlk/*' | sort
              )

              if [ "''${#files[@]}" -eq 0 ]; then
                echo "No playerbot SQL files found under $dir" >&2
                exit 1
              fi

              for f in "''${files[@]}"; do
                echo "Applying $f to $db"
                mariadb "$db" < "$f"
              done
            }

            applyBotSql classiccharacters ${botSql}/characters
            applyBotSql classicmangos ${botSql}/world

            echo "CMaNGOS database initialization complete!"
          '';
        };

        # service only gets created if gameAccounts is not empty
        systemd.services.cmangos-accounts = lib.mkIf (cfg.gameAccounts != {}) {
          description = "Create/update CMaNGOS declarative accounts via mangosd console";
          after = [ "mysql.service" "cmangos-db-init.service" ];
          before = [ "cmangos-mangosd.service" "cmangos-realmd.service" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            WorkingDirectory = "${cfg.cmangosDataDir}";
            runtimeDirectory = "cmangos-init";
          };

          path = with pkgs; [ mariadb pkgs.screen coreutils gnugrep ];

          # the script spins up a temporary cmangos instance with screen
          # and then loops over the game accounts and run the commands to add players.
          # done this way as usually the server console is interactive
          # checking for empty game accounts inside the script too
          script = ''
            ${if cfg.gameAccounts == {} then "echo 'No game accounts defined. Skipping.'; exit 0;" else ""}

          export SCREENDIR=$(mktemp -d)

          CONF=$(mktemp)
          cp /etc/cmangos/mangosd.conf "$CONF"
          echo "Console.Enable = 1" >> "$CONF"
          echo "WorldServerPort = 9999" >> "$CONF"
          echo "SOAP.Enable = 0" >> "$CONF"

            echo "Starting temporary mangosd instance in screen to process accounts..."
            screen -dmS mangos_init "${self.packages.${pkgs.system}.default}/bin/mangosd" -c $CONF

            echo "Waiting for server console to become ready..."
            sleep 10

            echo "Processing accounts..."
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (user: opts: ''
              USER_UPPER=$(echo "${user}" | tr '[:lower:]' '[:upper:]')

              EXISTS=$(mariadb -u root classicrealmd -Nse "SELECT COUNT(*) FROM account WHERE username='$USER_UPPER';")

              if [ "$EXISTS" -eq 0 ]; then
                echo "Creating new account: ${user}"
                screen -S mangos_init -X stuff "account create ${lib.escapeShellArg user} ${lib.escapeShellArg opts.password}\n"
                sleep 1
              else
                echo "Account ${user} exists. Ensuring password matched conf..."
                screen -S mangos_init -X stuff "account set password ${lib.escapeShellArg user} ${lib.escapeShellArg opts.password} ${lib.escapeShellArg opts.password}\n"
                sleep 1
              fi
            '') cfg.gameAccounts)}

            echo "Stopping temporary server instance..."
            screen -S mangos_init -X stuff "shutdown\n"

            echo "Waiting for server to save and release database..."
            sleep 8

            rm "$CONF"

            echo "Setting GM levels..."
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (user: opts: ''
              mariadb -u root classicrealmd -e "UPDATE account SET gmlevel=${toString opts.gmLevel} WHERE username='${lib.strings.toUpper user}';"
            '') cfg.gameAccounts)}

            echo "All declarative accounts processed!"
          '';
        };

        # login server, runs as cfg.user
        let
          # read the db password from file at service start, other config env overrides below
          realmdStart = pkgs.writeShellScript "realmd-start" ''
            pw=$(< "$CREDENTIALS_DIRECTORY/dbpass")
            export Realmd_LoginDatabaseInfo="127.0.0.1;3306;${cfg.dbUser};$pw;classicrealmd"
            exec ${self.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/realmd -c ${cfg.cmangosWorkingDir}/etc/realmd.conf
          '';
        in {
          systemd.services.cmangos-realmd = {
            description = "CMaNGOS Classic Logon Daemon";
            after = [ "network.target" "cmangos-db-init.service" ];
            requires = [ "cmangos-db-init.service" ];
            wantedBy = [ "multi-user.target" ];

            environment = mkEnv "Realmd_" ({
              ConfVersion = "2024020101";
              RealmServerPort = cfg.realmdPort;
            } // cfg.realmdSettings);

            serviceConfig = {
              LoadCredential = "dbpass:${cfg.dbPasswordFile}";
              ExecStart = realmdStart;
              WorkingDirectory = "${cfg.cmangosWorkingDir}/workingDir";
              User = cfg.user;
              Group = cfg.user;
              Restart = "always";
            };
          };
        }

        # world server, runs as cfg.user
        let
          # read the db password from file at service start, other config env overrides below
          mangosdStart = pkgs.writeShellScript "mangosd-start" ''
            pw=$(< "$CREDENTIALS_DIRECTORY/dbpass")
            export Mangosd_LoginDatabaseInfo="127.0.0.1;3306;${cfg.dbUser};$pw;classicrealmd"
            export Mangosd_WorldDatabaseInfo="127.0.0.1;3306;${cfg.dbUser};$pw;classicmangos"
            export Mangosd_CharacterDatabaseInfo="127.0.0.1;3306;${cfg.dbUser};$pw;classiccharacters"
            export Mangosd_LogsDatabaseInfo="127.0.0.1;3306;${cfg.dbUser};$pw;classiclogs"
            exec ${self.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/mangosd -c ${cfg.cmangosWorkingDir}/etc/mangosd.conf
          '';
        in {
        systemd.services.cmangos-mangosd = {
            description = "CMaNGOS Classic World Daemon";
            after = [ "network.target" "cmangos-db-init.service" ];
            requires = [ "cmangos-db-init.service" ];
            wantedBy = [ "multi-user.target" ];

            # mangosdconfig allows overwriting configuration fields with environment variables
            # env vars start with Mangosd_, points . are replaced with underscores _
            # e.g. Rate.Health -> Mangosd_Rate_Health=1.2, DataDir -> Mangosd_DataDir=/tmp
            # see the helper script mkEnv at the top of the file
            environment = mkEnv "Mangosd_" ({
              ConfVersion = 2024020101;
              RealmID = 1;
              DataDir = cfg.cmangosDataDir;
              WorldServerPort = cfg.mangosdPort;
              Console.Enable = 0;
              PlayerBots.Enable = 1;
              AhBot.Enable = 1;
              vmap.enableLOS = 1;
              vmap.enableHeight = 1;
              Anticheat.Enable = 0;
              Warden.Enable = 0;
            } // cfg.mangosdSettings);

            serviceConfig = {
              # pass the secret file to the service/user under $CREDENTIALS_DIRECTORY/dbpass
              LoadCredential = "dbpass:${cfg.dbPasswordFile}";
              ExecStart = mangosdStart;
              WorkingDirectory = "${cfg.cmangosWorkingDir}/workingDir";
              User = cfg.user;
              Group = cfg.user;
              Restart = "always";
            };
          };
        }

      };
    }

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
            realmAddress = "127.0.0.1";
            gameAccounts = {
              perttupeikko = { password = "password123"; gmLevel = 0; };
              hilmahaltia = { password = "password456"; gmLevel = 2; };
            };
          };

          # set vm to autologin to root, this is just for when you run the test vm
          users.users.root.password = "root";
          services.getty.autologinUser = "root";

          virtualisation.forwardPorts = [
            { from = "host"; host.port = 3724; guest.port = 3724; }  # realmd auth
            { from = "host"; host.port = 8085; guest.port = 8085; }  # mangosd world
          ];

          # share /var/lib/cmangos with the vm for testing
          virtualisation.sharedDirectories = {
            cmangos-data = {
              source = "/var/lib/cmangos";
              target = "/var/lib/cmangos";
            };
          };
        }
      ];
    };
  };
}
