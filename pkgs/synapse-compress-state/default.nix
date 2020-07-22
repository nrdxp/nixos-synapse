{ stdenv, fetchFromGitHub, rustPlatform }:
with rustPlatform;
buildRustPackage rec {
  pname = "synapse-compress-state";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "matrix-org";
    repo = "rust-synapse-compress-state";
    rev = "v${version}";
    hash = "sha256-0FH1adHdN/0k3mCt0R/mFPsyiHQoWstDYu1dg9edW5Y=";
  };

  cargoSha256 = "sha256-ZEnrpU1HImblYtwynAyQI/XUE9v+0rGmiIRaxuF6M4M=";
}
