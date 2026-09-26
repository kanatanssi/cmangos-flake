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
      url = "github:cmangos/playerbots";
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
          '';

          "cmangos/realmd.conf".text = ''
            [Realmd Conf]
            ConfVersion = 20250101
            LoginDatabaseInfo = "127.0.0.1;3306;${cfg.dbUser};${cfg.dbPassword};classicrealmd"
            RealmServerPort = ${toString cfg.realmdPort}
          '';
        };

        systemd.services.cmangos-db-init = {
          description = "Initialize CMaNGOS Classic from classic-db repo";
          after = [ "mysql.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = true;

          path = with pkgs; [ mariadb gzip ];

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

              echo "Extracting classic-db in scratch workspace..."
              WORK_DIR=$(mktemp -d)
              cp -r ${classic-db}/Full_DB/ClassicDB_*.sql.gz $WORK_DIR/classicdb.sql.gz

              cd $WORK_DIR

              gzip -d classicdb.sql.gz

              echo "Importing world data..."
              mariadb -u root classicmangos < classicdb.sql

              echo "Deleting scratch workspace..."
              cd /
              rm -rf $WORK_DIR

              echo "Applying classic-db content updates..."
              for update in ${classic-db}/Updates/*.sql; do
                if [ -f "$update" ]; then
                  echo "Applying content update: $(basename "$update")"
                  mariadb -u root classicmangos < "$update"
                fi
              done

              echo "Applying cmangos core updates, check if update is already included in classic-db..."
              echo "Will throw an error for every update not already applied while checking."
              for core_update in ${cmangos-src}/sql/updates/mangos/*.sql; do
                if [ -f "$core_update" ]; then
                  # Ajetaan päivitys. Jos se on jo olemassa, '|| true' estää palvelua kaatumaan ja jatkaa eteenpäin.
                  mariadb -u root classicmangos < "$core_update" || true
                fi
              done

              echo "CMaNGOS database initialization complete!"
            else
              echo "CMaNGOS databases already populated. Skipping initialization."
            fi


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
            gameAccounts = {
              perttupeikko = { password = "password123"; gmLevel = 0; };
              hilmahaltia = { password = "password456"; gmLevel = 2; };
            };
          };

          # set vm to autologin to root, this is just for when you run the test vm
          users.users.root.password = "root";
          services.getty.autologinUser = "root";

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
