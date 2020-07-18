{
  description = "Deploy Synapse Server to EC2";

  inputs.nixpkgs.url = "nixpkgs/release-20.03";
  inputs.unstable.url = "nixpkgs/master";
  inputs.nixflk.url = "github:nrdxp/nixflk";

  outputs = { self, nixpkgs, unstable, nixops, nixflk }:
    with nixpkgs.lib;
    let
      system = "x86_64-linux";
      pkgs_ = import nixpkgs { inherit system; };
      unstablePkgs = import unstable { inherit system; };

      region = "us-west-1";
      accessKeyId = fileContents ./secrets/keyid;
      address = fileContents ./secrets/ip;

      database_pass = fileContents ./secrets/database;
    in {
      devShell."${system}" =
        pkgs_.mkShell { buildInputs = [ nixops.defaultPackage."${system}" ]; };

      nixopsConfigurations = {
        default = {
          inherit nixpkgs;
          network.description = "Synapse Server";

          synapse-server = { resources, pkgs, config, ... }: {
            imports = with nixflk.nixosModules.profiles; [
              ./modules/jitsi-meet.nix
              core
              develop
            ];

            nixpkgs.config.allowUnfree = true;

            users.users.root.hashedPassword = fileContents ./secrets/root;

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

            environment.systemPackages = with pkgs; [ riot-web ];
            nixpkgs.overlays = [
              nixflk.overlays.kakoune
              nixflk.overlays.pkgs
              (self: super: {
                riot-web = unstablePkgs.riot-web.override {
                  conf = {
                    default_server_config = {
                      "m.homeserver" = {
                        "base_url" = "https://matrix.nrdxp.dev";
                        "server_name" = "nrdxp.dev";
                      };
                      "m.identity_server" = {
                        "base_url" = "https://vector.im";
                      };
                    };

                    ## jitsi will be setup later,
                    ## but we need to add to Riot configuration
                    jitsi.preferredDomain = "jitsi.nrdxp.dev";
                  };
                };
                matrix-synapse = unstablePkgs.matrix-synapse;
              })
            ];

            services.jitsi-meet = {
              enable = true;
              hostName = "jitsi.nrdxp.dev";
            };

            services.jitsi-videobridge.openFirewall = true;

            services.coturn = {
              enable = true;
              use-auth-secret = true;
              static-auth-secret = fileContents ./secrets/turn;
              realm = "turn.nrdxp.dev";
              no-tcp-relay = true;
              extraConfig = ''
                user-quota=12
                total-quota=1200
                denied-peer-ip=10.0.0.0-10.255.255.255
                denied-peer-ip=192.168.0.0-192.168.255.255
                denied-peer-ip=172.16.0.0-172.31.255.255

                allowed-peer-ip=192.168.191.127

                cipher-list="HIGH"
                no-loopback-peers
                no-multicast-peers
              '';

              secure-stun = true;
              cert = "/var/lib/acme/turn.nrdxp.dev/fullchain.pem";
              pkey = "/var/lib/acme/turn.nrdxp.dev/key.pem";

              min-port = 49152;
              max-port = 49999;
            };

            systemd.services.matrix-synapse.serviceConfig.Restart =
              mkForce "always";

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
                { # federation
                  bind_address = "";
                  port = 8448;
                  resources = [
                    {
                      compress = false;
                      names = [ "federation" ];
                    }
                    {
                      compress = true;
                      names = [ "client" "webclient" ];
                    }
                  ];
                  type = "http";

                  tls = true;
                  x_forwarded = false;
                }
                { # client
                  port = 8008;
                  resources = [{
                    compress = true;
                    names = [ "client" "webclient" ];
                  }];
                  tls = false;
                }
              ];

              turn_uris = [
                "turn:turn.dangerousdemos.net:3478?transport=udp"
                "turn:turn.dangerousdemos.net:3478?transport=tcp"
              ];

              turn_shared_secret = config.services.coturn.static-auth-secret;

              extraConfig = ''
                max_upload_size: "10M"
              '';
            };

            # web client proxy and setup certs
            services.nginx = {
              enable = true;

              recommendedGzipSettings = true;
              recommendedOptimisation = true;
              recommendedTlsSettings = true;

              virtualHosts = {
                "matrix.nrdxp.dev" = {
                  forceSSL = true;
                  enableACME = true;
                  locations."/" = { proxyPass = "http://127.0.0.1:8008"; };
                };
                "riot.nrdxp.dev" = {
                  forceSSL = true;
                  enableACME = true;
                  locations."/" = { root = pkgs.riot-web; };
                };
                "${config.services.jitsi-meet.hostName}" = {
                  enableACME = true;
                  forceSSL = true;
                };
                "turn.nrdxp.dev" = {
                  enableACME = true;
                  forceSSL = true;
                };
              };
            };

            # share certs with matrix-synapse and restart on renewal
            security.acme = {
              email = "tim@nrdxp.dev";
              acceptTerms = true;
              certs = {
                "turn.nrdxp.dev" = {
                  group = "turnserver";
                  allowKeysForGroup = true;
                  postRun =
                    "systemctl reload nginx.service; systemctl restart coturn.service";
                };

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

            networking.firewall = let
              range = with config.services.coturn; {
                from = min-port;
                to = max-port;
              };
            in {
              enable = true;
              allowedUDPPorts = [ 3478 5349 5350 ];
              allowedUDPPortRanges = [ range ];
              allowedTCPPortRanges = [ range ];

              allowedTCPPorts = [ 22 80 443 3478 3479 8448 ];
            };
          };

          resources = {
            ec2KeyPairs.nrdxp-keys = { inherit region accessKeyId; };
          };
        };
      };
    };
}

