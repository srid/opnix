{ lib, pkgs, config, utils, ... }:
with lib;
let
  inherit (import ./types.nix {
    inherit lib;
    inherit config;
  })
    secretFileDeclaration;
  cfg = config.opnix;
  scripts = import ./scripts.nix {
    inherit lib;
    inherit config pkgs;
  };

  shellApp = pkgs.writeShellApplication {
    name = "mount.opnix";
    text = ''
      set -x
      ${scripts.newGeneration}
      ${scripts.installSecrets}
      ${scripts.chownSecrets}
    '';
  };

  sbinApp = pkgs.runCommand "mount.opnix" {} ''
    mkdir -p $out/sbin $out/bin
    (
      cd $out/sbin
      ln -s ${shellApp}/bin/mount.opnix
    )
    (
      cd $out/bin
      ln -s ${shellApp}/bin/mount.opnix
    )
  '';
in {
  options.opnix = {
    opBin = mkOption {
      type = types.str;
      default = "${pkgs._1password}/bin/op";
      description = "The 1Password CLI `op` executable to use";
    };
    environmentFile = mkOption {
      type = types.str;
      description = ''
        Path to a environment file which contains your service account token. Format should be `OP_SERVICE_ACCOUNT_TOKEN="{ your token here }"`. This is used to authorize the 1Password CLI in the systemd job.'';
    };
    secretsDir = mkOption {
      type = types.path;
      default = "/run/opnix";
      description = ''
        Directory where secrets are symlinked to
      '';
    };
    secretsMountPoint = mkOption {
      type = types.addCheck types.str (s:
        (trim s) != "" # non-empty
        && (builtins.match ".+/" s) == null) # without trailing slash
        // {
          description =
            "${types.str.description} (with check: non-empty without trailing slash)";
        };
      default = "/run/opnix.d";
    };
    secrets = mkOption {
      type = types.attrsOf secretFileDeclaration;
      description = "The secrets you want to use in your NixOS deployment";
      default = { };
      example = {
        my-secret = {
          source = "{{ op://VaultName/ItemName/FieldName }}";
          mode = "0400";
          inherit (config.services.some_service) user;
          inherit (config.services.some_service) group;
        };
        another-secret.source = ''
          [SomeTomlHeader]
          SomeValue = "{{ op://AnotherVault/AnotherItem/AnotherField }}"
        '';
      };
    };
    systemdWantedBy = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        A list of `systemd` service names that depend on secrets from `opnix`. This option will set `after = [ "opnix.service" ]` and `wants = [ "opnix.service" ]` for each specified `systemd` unit.'';
      example = [ "homepage-dashboard" "wg-quick-vpn" ];
    };
  };
  config = mkIf (cfg.secrets != { }) (mkMerge [
    {
      systemd.mounts = [{
        #what = cfg.environmentFile;
        what = "opnix";
        where = cfg.secretsDir;
        type = "opnix";
        options = "";
        # options

        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];

        unitConfig = {
          ConditionPathExists = cfg.secretsDir;
          ConditionCapability = "CAP_SYS_ADMIN";
        };

        mountConfig = {
        };
      }];

      environment.systemPackages = [ sbinApp ];
      system.fsPackages = [ sbinApp ];

      system = {
        activationScripts = {
          # Create a new directory full of secrets for symlinking (this helps
          # ensure removed secrets are actually removed, or at least become
          # invalid symlinks).
          opnixNewGeneration = {
            text = ''
              #mkdir -p ${cfg.secretsDir}
            '';
            deps = [ "specialfs" ];
          };
        };
      };
    }
    # {
    #   systemd.services = builtins.listToAttrs (builtins.map (systemdName: {
    #     name = systemdName;
    #     value = {
    #       after = [ "opnix.service" ];
    #       wants = [ "opnix.service" ];
    #     };
    #   }) cfg.systemdWantedBy);
    # }
  ]);
}
