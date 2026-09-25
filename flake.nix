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

    # submodule cmake tries to pull
    cmangos-zlib = {
      url = "github:madler/zlib/v1.3.1"; # Tarkista versio CMaNGOSin koodeista jos tarpeen
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

        # CMaNGOS defaults to searching for static Boost libraries
        # NixOS provides shared/dynamic libraries by default in 'pkgs.boost'.
        # We patch CMakeLists.txt to force dynamic linking, preventing build failures due to missing static assets.

        # Manually move out-of-tree modules (like PlayerBots) into the sandbox's source tree before configuration.
        # This tricks CMake into thinking the repository was natively populated via a download phase.
        preConfigure = ''
          substituteInPlace CMakeLists.txt \
            --replace "set(Boost_USE_STATIC_LIBS ON)" "set(Boost_USE_STATIC_LIBS OFF)"

          mkdir -p src/modules
          cp -r ${cmangos-playerbots} src/modules/PlayerBots
          chmod -R +w src/modules/PlayerBots
        '';

        # Bypass CMaNGOS's internal FetchContent routine for zlib.
        # Forcing 'if(FALSE)' routes CMake straight to the else() block where it uses our predefined Nix zlib flags.
        postPatch = ''
          sed -i 's/if (NOT ZLIB_FOUND.*/if (FALSE)/' dep/src/CMakeLists.txt
        '';

        cmakeFlags = [
          "-DDEBUG=0"
          "-DBUILD_PLAYERBOTS=ON"
          "-DBUILD_AHBOT=ON"
          "-DBUILD_EXTRACTORS=ON"
          "-DCMAKE_INSTALL_PREFIX=${placeholder "out"}"

          # Explicitly point to Nix-provided MariaDB connector paths to prevent CMake from searching host directories.
          "-DMYSQL_INCLUDE_DIR=${pkgs.lib.getDev pkgs.mariadb-connector-c}/include/mariadb"
          "-DMYSQL_LIBRARY=${pkgs.lib.getLib pkgs.mariadb-connector-c}/lib/mariadb/libmariadb.so"

          # Enforce offline build by blocking CMake from making automatic git/network clones.
          "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"

          # Provide the exact header and library paths for the Nix-packaged zlib dependency.
          "-DZLIB_INCLUDE_DIRS=${pkgs.zlib.dev}/include"
          "-DZLIB_LIBRARIES=${pkgs.zlib}/lib/libz.so"
        ];
      };
    };
  };

}
