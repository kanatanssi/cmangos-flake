{
  description = "A Nix flake for running a CMaNGOS Classic WoW Server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    cmangos-src = {
      url = "github:cmangos/mangos-classic/master";
      flake = false;
    };

    classic-db = {
      url = "github:cmangos/classic-db/master";
      flake = false;
    };

    # submodules downloaded by cmangos
    cmangos-zlib = {
      url = "github:madler/zlib/master";
      flake = false;
    };

    cmangos-g3dlite = {
      url = "github:cmangos/g3dlite/master";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, cmangos-src, cmangos-zlib, cmangos-g3dlite }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      packages.${system} = {
        default = pkgs.stdenv.mkDerivation {
          pname = "cmangos-classic";
          version = "date=${cmangos-src.lastModifiedDate or "unknown"}-${cmangos-src.shortRev or "dirty"}";

          src = cmangos-src;

          # Insert submodules downloaded above
          postUnpack = ''
            rm -rf $sourceRoot/src/dep/zlib
            cp -r ${cmangos-zlib} $sourceRoot/src/dep/zlib
            chmod -R +w $sourceRoot/src/dep/zlib

            rm -rf $sourceRoot/src/dep/g3dlite
            cp -r ${cmangos-g3dlite} $sourceRoot/src/dep/g3dlite
            chmod -R +w $sourceRoot/src/dep/g3dlite
          '';

          nativeBuildInputs = with pkgs; [ cmake gcc pkg-config git ];
          buildInputs = with pkgs; [ mariadb-connector-c ];

          hardeningDisable = [ "format" ];

          preConfigure = ''
            substituteInPlace CMakeLists.txt \
              --replace "set(Boost_USE_STATIC_LIBS ON)" "set(Boost_USE_STATIC_LIBS OFF)"
          '';

          cmakeFlags = [
            "-DDEBUG=0"
            "-DBUILD_PLAYERBOTS=ON"
            "-DBUILD_AHBOT=ON"
            "-DBUILD_EXTRACTORS=ON"
            "-DCMAKE_INSTALL_PREFIX=${placeholder "out"}"
            "-DMYSQL_INCLUDE_DIR=${pkgs.lib.getDev pkgs.mariadb-connector-c}/include/mariadb"
            "-DMYSQL_LIBRARY=${pkgs.lib.getLib pkgs.mariadb-connector-c}/lib/mariadb/libmariadb.so"
          ];
        };
      };
    };
}
