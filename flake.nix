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

        dbUser = lib.mkOption {
          type = lib.types.str;
          default = "mangos";
        };

        dbPassword = lib.mkOption {
          type = lib.types.str;
          default = "mangos";
        };
      };

      config = lib.mkIf cfg.enable {
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


            if [ $(mysql -u root -Nse "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='classicrealmd'") -eq 0 ]; then
              echo "CMaNGOS dbs empty. Initializing base structures..."

              echo "Applying core base structures..."
              mariadb -u root classicrealmd < ${cmangos-src}/sql/base/realmd.sql
              mariadb -u root classiccharacters < ${cmangos-src}/sql/base/characters.sql
              mariadb -u root classicmangos < ${cmangos-src}/sql/base/mangos.sql
              mariadb -u root classicmangos < ${cmangos-src}/sql/base/logs.sql

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
                  UPDATE_NAME=$(basename "$core_update" .sql)

                   if mariadb -u root classicmangos -e "SELECT 1 FROM db_version WHERE version = '$UPDATE_NAME' OR updates LIKE '%$UPDATE_NAME%'" >/dev/null 2>&1; then
                    echo "Core update $UPDATE_NAME already applied by Classic-DB. Skipping."
                  else
                  echo "Applying missing core update: $UPDATE_NAME"
                    mariadb -u root classicmangos < "$core_update" || true
                  fi
                fi
              done

              echo "CMaNGOS database initialization complete!"
            else
              echo "CMaNGOS databases already populated. Skipping initialization."
            fi
          '';
        };
      };
    };

    # vm for testing
    nixosConfigurations.testVM = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.default
        {
          services.cmangos-server.enable = true;

          # set vm to autologin to root, this is just for when you run the test vm
          users.users.root.password = "root";
          services.getty.autologinUser = "root";

          # minimal settings to allow vm to boot
          fileSystems."/" = { device = "/dev/disk/by-label/nixos"; };
          boot.loader.grub.enable = false;
        }
      ];
    };
  };
}
