self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.freespin;
  json = pkgs.formats.json { };
  raw = json.generate "freespin-config.json" cfg.settings;
  # Validated at build time, so a typo fails `home-manager switch` instead of the agent.
  configFile = pkgs.runCommand "freespin-config.json" { } ''
    ${lib.getExe cfg.package} daemon --check --config ${raw}
    cp ${raw} $out
  '';
  logFile = "${config.home.homeDirectory}/Library/Logs/freespin.log";
  # TCC keys a bare executable's grants on its path as well as its signature, so the agent runs a copy at a
  # fixed path instead of the store path, which changes with every update.
  binary = "${config.home.homeDirectory}/Library/Application Support/Freespin/bin/freespinctl";
in
{
  options.services.freespin = {
    enable = lib.mkEnableOption "Freespin, a headless driver for Logitech mice (`freespinctl daemon`)";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.freespinctl;
      defaultText = lib.literalExpression "freespin.packages.\${system}.freespinctl";
      description = "The signed freespinctl binary.";
    };

    settings = lib.mkOption {
      type = json.type;
      default = { };
      description = ''
        Contents of the daemon's JSON config. Anything left out keeps the value the device already has.
        See `freespinctl daemon --help` and the README for the keys.
      '';
      example = lib.literalExpression ''
        {
          default = { scrollSpeed = 60; smoothScrolling = true; };
          devices."MX Master 3S" = {
            dpi = 1600;
            buttons = { gesture = "gestures"; back = "missionControl"; };
            apps."com.apple.Safari".scrollSpeed = 45;
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      (lib.hm.assertions.assertPlatform "services.freespin" pkgs lib.platforms.darwin)
      {
        assertion = !(cfg.package ? version) || lib.versionAtLeast cfg.package.version "0.3.0";
        message = ''
          services.freespin: freespinctl ${cfg.package.version or ""} has no `daemon` command; it arrives in 0.3.0.
          Update the freespin flake input once that release is out, or set services.freespin.package.
        '';
      }
    ];

    home.packages = [ cfg.package ];

    home.activation.freespinBinary = lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ] ''
      if ! cmp -s ${lib.getExe cfg.package} ${lib.escapeShellArg binary}; then
        run mkdir -p ${lib.escapeShellArg (builtins.dirOf binary)}
        run install -m 755 ${lib.getExe cfg.package} ${lib.escapeShellArg binary}
      fi
    '';

    # The config and package store paths are in the plist, so changing either changes it and home-manager
    # restarts the daemon on switch.
    launchd.agents.freespin = {
      enable = true;
      config = {
        ProgramArguments = [ binary "daemon" "--config" "${configFile}" ];
        EnvironmentVariables.FREESPIN_PACKAGE = "${cfg.package}";
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Interactive";
        StandardOutPath = logFile;
        StandardErrorPath = logFile;
      };
    };
  };
}
