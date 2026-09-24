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
  };

  outputs = { self, nixpkgs, cmangos-src }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      packages.${system} = {
        default = pkgs.stdenv.mkDerivation {
          pname = "cmangos-classic";
          version = "date=${cmangos-src.lastModifiedDate or "unknown"}-${cmangos-src.shortRev or "dirty"}";

          src = cmangos-src;

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
