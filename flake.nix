{
  description = "Development tools for ZODL Swift Wallet SDK";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      forEachSystem = f:
        nixpkgs.lib.genAttrs
          [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ]
          (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # Tools for regenerating the protobuf/gRPC Swift sources; see
      # Scripts/update-lightwallet-protocol.sh. The protoc-gen-swift and
      # protoc-gen-grpc-swift plugins are intentionally not provided here:
      # they are built from the swift-protobuf / grpc-swift versions pinned
      # in Package.resolved so that generated code matches the runtime
      # libraries the SDK links against.
      devShells = forEachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.protobuf ];
        };
      });
    };
}
