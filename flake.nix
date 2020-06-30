{
  description = "Deploy Synapse Server to EC2";

  inputs.nixpkgs.url = "nixpkgs/release-20.03";

  outputs = { self, nixpkgs, nixops }:
    with nixpkgs.lib;
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      region = "us-west-1";
      accessKeyId = fileContents ./secrets/keyid;
      address = fileContents ./secrets/ip;

      database_pass = fileContents ./secrets/database;
    in {
      devShell."${system}" =
        pkgs.mkShell { buildInputs = [ nixops.defaultPackage."${system}" ]; };

      nixopsConfigurations = {
        default = {
          inherit nixpkgs;
          network.description = "Synapse Server";

          synapse-server = { resources, ... }: {
            deployment = {
              targetEnv = "ec2";
              ec2 = {
                accessKeyId = accessKeyId;
                region = region;
                instanceType = "t2.micro";
                keyPair = resources.ec2KeyPairs.nrdxp-keys;
                elasticIPv4 = address;
              };
            };

            services.matrix-synapse = {
              enable = true;
              server_name = "nrdxp.dev";
              registration_shared_secret = fileContents ./secrets/registration;
              public_baseurl = "https://matrix.nrdxp.dev/";
              database_args.password = database_pass;
              database_args.database = "matrix-synapse";
              tls_certificate_path =
                "/var/lib/acme/matrix.nrdxp.dev/fullchain.pem";
              tls_private_key_path = "/var/lib/acme/matrix.nrdxp.dev/key.pem";
              listeners = [
                # client
                {
                  port = 8008;
                  resources = [{
                    compress = true;
                    names = [ "client" "federation" ];
                  }];
                  tls = false;
                }
              ];
              extraConfig = ''
                max_upload_size: "10M"
              '';
            };

            # web client proxy and setup certs
            services.nginx = {
              enable = true;
              virtualHosts = {
                "matrix.nrdxp.dev" = {
                  forceSSL = true;
                  enableACME = true;
                  locations."/" = { proxyPass = "http://127.0.0.1:8008"; };
                };
              };
            };

            # share certs with matrix-synapse and restart on renewal
            security.acme = {
              email = "tim@nrdxp.dev";
              acceptTerms = true;
              certs = {
                "matrix.nrdxp.dev" = {
                  group = "matrix-synapse";
                  allowKeysForGroup = true;
                  postRun =
                    "systemctl reload nginx.service; systemctl restart matrix-synapse.service";
                };
              };
            };

            services.postgresql = {
              enable = true;
              initialScript = pkgs.writeText "synapse-init.sql" ''
                CREATE ROLE "matrix-synapse" WITH LOGIN PASSWORD '${database_pass}';
                CREATE DATABASE "matrix-synapse" WITH OWNER "matrix-synapse"
                  TEMPLATE template0
                  LC_COLLATE = "C"
                  LC_CTYPE = "C";
              '';
            };

            networking.firewall = {
              enable = true;
              allowedTCPPorts = [
                22
                8448 # Matrix federation
                80
                443
              ];
            };
          };

          resources = {
            ec2KeyPairs.nrdxp-keys = { inherit region accessKeyId; };
          };
        };
      };
    };
}

