# packages/openclaw/default.nix
#
# Vendored OpenClaw package — built from the npm registry tarball using
# buildNpmPackage for full reproducibility (no npm at runtime).
#
# To update:
#   1. Bump `version` to the new release tag
#   2. Update `hash` on the fetchurl (nix will tell you the new hash on mismatch)
#   3. Regenerate package-lock.json:
#        tmp=$(mktemp -d)
#        curl -fsSL https://registry.npmjs.org/openclaw/-/openclaw-<VERSION>.tgz | tar xz -C "$tmp"
#        cd "$tmp/package" && npm install --package-lock-only --legacy-peer-deps
#        cp package-lock.json /path/to/packages/openclaw/package-lock.json
#   4. Update `npmDepsHash` (nix will tell you the new hash on mismatch)
#
# Build logic adapted from Scout-DJ/openclaw-nix (MIT), vendored here so we
# control the supply chain — no third-party flake inputs for runtime code.

{ lib, stdenv, fetchurl, buildNpmPackage, nodejs_22, python3, pkg-config, makeWrapper, vips }:

let
  version = "2026.2.6-3";
  nodejs = nodejs_22;

  # The npm tarball doesn't include a lockfile, so we combine it with our
  # vendored package-lock.json to satisfy buildNpmPackage.
  src = stdenv.mkDerivation {
    name = "openclaw-src-${version}";
    src = fetchurl {
      url = "https://registry.npmjs.org/openclaw/-/openclaw-${version}.tgz";
      hash = "sha256-zDMRFzjdetdw0Q47uqCIKHoqV7UwjxKnS6L9u2VoTJM=";
    };
    phases = [ "unpackPhase" "installPhase" ];
    sourceRoot = "package";
    installPhase = ''
      cp -r . $out
      cp ${./package-lock.json} $out/package-lock.json
    '';
  };
in
buildNpmPackage {
  pname = "openclaw";
  inherit version src;

  npmDepsHash = "sha256-NPUq7InJJI00fVhmN6VUVcR7+lZrgl6AFNPdRYGb/Ms=";

  inherit nodejs;

  # Skip native compilation of optional deps; sharp uses prebuilt binaries.
  npmFlags = [ "--ignore-scripts" "--legacy-peer-deps" ];
  makeCacheWritable = true;

  nativeBuildInputs = [ python3 pkg-config makeWrapper ];
  buildInputs = [ vips ];

  # The package ships pre-built (dist/ is in the tarball), so no build step.
  dontNpmBuild = true;

  postInstall = ''
    # Let sharp find its prebuilt platform binary (fails gracefully if sandboxed).
    cd $out/lib/node_modules/openclaw
    ${nodejs}/bin/node node_modules/sharp/install/check.js 2>/dev/null || true

    # Create the openclaw wrapper pointing at the installed entrypoint.
    mkdir -p $out/bin
    rm -f $out/bin/openclaw 2>/dev/null || true
    makeWrapper "${nodejs}/bin/node" "$out/bin/openclaw" \
      --add-flags "$out/lib/node_modules/openclaw/openclaw.mjs" \
      --set NODE_PATH "$out/lib/node_modules"
  '';

  meta = with lib; {
    description = "OpenClaw — AI agent infrastructure platform";
    homepage = "https://openclaw.ai";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "openclaw";
  };
}
