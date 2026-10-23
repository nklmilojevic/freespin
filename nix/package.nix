{ lib, stdenvNoCC, fetchurl }:

let
  release = lib.importJSON ./release.json;
in
# The signed release binary, not a local build: Accessibility and Input Monitoring grants are tied to the
# Developer ID signature, so a binary signed by anything else would have to be granted again on every update.
stdenvNoCC.mkDerivation {
  pname = "freespinctl";
  inherit (release) version;

  src = fetchurl {
    url = "https://github.com/nklmilojevic/freespin/releases/download/v${release.version}/freespinctl-${release.version}-macos.tar.gz";
    inherit (release) hash;
  };

  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  # Stripping or patching would invalidate the code signature.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 freespinctl $out/bin/freespinctl
    runHook postInstall
  '';

  meta = {
    description = "Headless driver for Logitech HID++ mice: smooth scrolling, buttons, SmartShift and Flow";
    homepage = "https://github.com/nklmilojevic/freespin";
    platforms = lib.platforms.darwin;
    mainProgram = "freespinctl";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
