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

        dbPassword = lib.mkOption {
          type = lib.types.str;
          default = "mangos";
        };

        cmangosDataDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/cmangos";
          description = "Location of map data extracted from Wow Classic client.";
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

        assertions = lib.mapAttrsToList (name: value: {
          assertion = (builtins.match "[a-zA-Z0-9_]+" name) != null;
          message = "CMaNGOS account username '${name}' contains invalid characters! Only alphanumeric characters and underscores are allowed.";
        }) cfg.gameAccounts ++ lib.mapAttrsToList (name: value: {
          assertion = lib.stringLength name <= 16;
          message = "CMaNGOS account username '${name}' is too long! Maximum length is 16 characters.";
        }) cfg.gameAccounts;

        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.user;
          description = "CMaNGOS daemon user";
        };
        users.groups.${cfg.user} = {};

        networking.firewall = lib.mkIf cfg.openPorts {
          allowedTCPPorts = [ cfg.realmdPort cfg.mangosdPort ];
          allowedUDPPorts = [ cfg.realmdPort cfg.mangosdPort ];
        };

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

        environment.etc = {
          "cmangos/mangosd.conf".text = ''
            [Mangosd Conf]
            ConfVersion = 20250101
            RealmID = 1
            DataDir = "${cfg.cmangosDataDir}"
            WorldServerPort = ${toString cfg.mangosdPort}
            LoginDatabaseInfo     = "127.0.0.1;3306;${cfg.dbUser};${cfg.dbPassword};classicrealmd"
            WorldDatabaseInfo     = "127.0.0.1;3306;${cfg.dbUser};${cfg.dbPassword};classicmangos"
            CharacterDatabaseInfo = "127.0.0.1;3306;${cfg.dbUser};${cfg.dbPassword};classiccharacters"
            LogsDatabaseInfo      = "127.0.0.1;3306;${cfg.dbUser};${cfg.dbPassword};classiclogs"
            MaxPlayerLimit = 10
            Console.Enable = 0
            PlayerBots.Enable = 1
            AhBot.Enable = 1
            vmap.enableLOS = 1
            vmap.enableHeight = 1
          '';

          "cmangos/realmd.conf".text = ''
            [Realmd Conf]
            ConfVersion = 20250101
            LoginDatabaseInfo = "127.0.0.1;3306;${cfg.dbUser};${cfg.dbPassword};classicrealmd"
            RealmServerPort = ${toString cfg.realmdPort}
          '';

          "cmangos/InstallFullDB.config".text = ''
            # Database connection
            MYSQL_HOST="localhost"
            MYSQL_PORT="3306"
            MYSQL_USERNAME="${cfg.dbUser}"
            MYSQL_PASSWORD="${cfg.dbPassword}"
            MYSQL_PATH="mysql"
            MYSQL_DUMP_PATH="mysqldump"

            # Target db
            WORLD_DB_NAME="classicmangos"

            # Point to mangos-classic repo
            CORE_PATH="${cmangos-src}"

            # Optional, YES/NO
            AHBOT="YES"
            PLAYERBOTS_DB="YES"

            # Skip 10-second warning
            FORCE_WAIT="NO"
          '';

          "cmangos/aiplayerbot.conf".text = ''
            [AiPlayerbot]
            ConfVersion = 20250101
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
            ConfVersion = 20250101

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

        systemd.services.cmangos-db-init = {
          description = "Initialize CMaNGOS Classic from classic-db repo";
          after = [ "mysql.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = true;

          path = with pkgs; [ mariadb gzip bash python3 ];

          script = ''
            until mariadb-admin ping -u root --silent; do
              sleep 1
            done

            echo "Configuring traditional password authentication for ${cfg.dbUser}..."
            mariadb -u root -e "ALTER USER '${cfg.dbUser}'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${cfg.dbPassword}'); FLUSH PRIVILEGES;"


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

              echo "CMaNGOS database initialization complete!"
            else
              echo "CMaNGOS databases already populated. Skipping initialization."
            fi
          '';
        };

        # Service only gets created if gameAccounts is not empty
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

          # Checking for empty game accounts inside the script too
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
        systemd.services.cmangos-realmd = {
          description = "CMaNGOS Classic Logon Daemon";
          after = [ "network.target" "cmangos-db-init.service" ];
          requires = [ "cmangos-db-init.service" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            ExecStart = "${self.packages.${pkgs.system}.default}/bin/realmd -c /etc/cmangos/realmd.conf";
            WorkingDirectory = "${cfg.cmangosDataDir}";
            User = cfg.user;
            Group = cfg.user;
            Restart = "always";
            Type = "simple";
          };
        };

        # world server, runs as cfg.user
        systemd.services.cmangos-mangosd = {
          description = "CMaNGOS Classic World Daemon";
          after = [ "network.target" "cmangos-db-init.service" ];
          requires = [ "cmangos-db-init.service" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            ExecStart = "${self.packages.${pkgs.system}.default}/bin/mangosd -c /etc/cmangos/mangosd.conf";
            WorkingDirectory = "${cfg.cmangosDataDir}";
            User = cfg.user;
            Group = cfg.user;
            Restart = "always";
            Type = "simple";
          };
        };

        # ensure that the data dir exists for the service user
        systemd.tmpfiles.rules = [
          "d ${cfg.cmangosDataDir} 0755 ${cfg.user} ${cfg.user} -"
        ];

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
