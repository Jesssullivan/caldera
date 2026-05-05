{
  description = "Tinyland public fork of MITRE Caldera — devShell + reproducible image build for on-prem deployment with Shibboleth SAML auth";

  inputs = {
    # Match GloriousFlywheel's nixpkgs channel for cache compatibility.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";

    # Consistent formatting.
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # `nix2container` is added in the follow-up commit that introduces
    # `packages.container` (TIN-969). Keep this input set lean for now.
  };

  outputs = { self, nixpkgs, flake-utils, treefmt-nix }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          # Caldera vendors the unmaintained `xmlsec==1.3.9` python package via
          # the SAML plugin's requirements.txt. We do not run that here; instead
          # we expose the native libraries (libxmlsec1, libxml2, etc.) so a
          # developer-side `pip install` can build the wheel against modern
          # libs. No insecure-package overrides are needed at the flake level.
        };

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs = {
            nixpkgs-fmt.enable = true;
            shfmt.enable = true;
          };
          # Don't try to format upstream paths — keeps merges with mitre/caldera clean.
          settings.formatter.nixpkgs-fmt.includes = [ "flake.nix" "tinyland/**/*.nix" ];
          settings.formatter.shfmt.includes = [ "tinyland/**/*.sh" ];
        };

        # Python toolchain. Caldera supports 3.10+; we pin to 3.12 since 3.11
        # has the well-known sphinx-9.1 build hiccup in nixpkgs and we don't
        # need 3.11 for any compat reason.
        python = pkgs.python312;

        # The dev shell is intentionally close to GloriousFlywheel's default
        # so contributors with both flakes get consistent tooling.
        devTools = with pkgs; [
          # ---- Caldera core runtime
          python
          python.pkgs.pip
          python.pkgs.virtualenv
          uv

          # ---- sandcat agent (Go)
          go_1_24
          gopls

          # ---- magma VueJS UI
          nodejs_22
          nodePackages.pnpm

          # ---- SAML plugin native deps
          # python3-saml depends on `xmlsec` which links against libxmlsec1.
          # libxml2 and libxslt are required for lxml. pkg-config helps the
          # `pip install` discover the headers.
          libxml2.dev
          libxslt.dev
          xmlsec.dev
          xmlsec # `xmlsec1` CLI for ad-hoc verification
          pkg-config

          # ---- Infrastructure / deploy tooling
          kubectl
          kubernetes-helm
          k9s
          kustomize
          opentofu
          sops
          age

          # ---- Container tooling
          skopeo
          dive
          cosign

          # ---- Dev convenience
          just
          jq
          yq-go
          curl
          gnumake
          git
          git-lfs
          direnv
          nix-direnv

          # ---- Nix lint / format
          nixpkgs-fmt
          statix
          deadnix
        ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
          # Cross-compile for sandcat Windows agent — nixpkgs' mingw cross
          # toolchain is Linux-only. macOS contributors fall back to
          # `--build` mode in the upstream Caldera Dockerfile.
          pkgs.pkgsCross.mingwW64.buildPackages.gcc
        ];

      in
      {
        devShells.default = pkgs.mkShell {
          name = "caldera-tinyland-dev";
          packages = devTools;

          # Wire up Attic for Nix substitution. CI's setup-flywheel composite
          # action injects the trust-pinning; locally, contributors who have
          # already authenticated against the cache get hits for free.
          ATTIC_CACHE_URL = "https://nix-cache.tinyland.dev";

          # SAML plugin's xmlsec build needs to find libxmlsec1 headers + libs.
          # Without this, `pip install xmlsec==1.3.9` fails to compile on
          # macOS in particular. Setting these here keeps `pip` working
          # without a per-command env-var dance.
          PKG_CONFIG_PATH = pkgs.lib.makeSearchPath "lib/pkgconfig" [
            pkgs.libxml2.dev
            pkgs.libxslt.dev
            pkgs.xmlsec.dev
          ];

          shellHook = ''
            echo "Caldera (Tinyland fork) Development Environment"
            echo "==============================================="
            echo ""
            echo "  python: $(${python}/bin/python --version)"
            echo "  go:     $(${pkgs.go_1_24}/bin/go version | awk '{print $3}')"
            echo "  node:   $(${pkgs.nodejs_22}/bin/node --version)"
            echo ""
            echo "Quick start:"
            echo "  python -m venv .calderavenv && . .calderavenv/bin/activate"
            echo "  pip install -r requirements.txt"
            echo "  python3 server.py --insecure --build"
            echo ""
            echo "SAML plugin contributors:"
            echo "  cd plugins/saml && pip install -r requirements.txt"
            echo "  pytest tests/test_v5_compat_unit.py -v   # unit (no caldera tree)"
            echo ""
            if [ -n "''${BAZEL_REMOTE_CACHE:-}" ]; then
              echo "Cache: ''${BAZEL_REMOTE_CACHE} (set by setup-flywheel)"
            elif [ -n "''${ATTIC_CACHE_URL:-}" ]; then
              echo "Attic: $ATTIC_CACHE_URL"
            fi
          '';
        };

        # Lightweight CI shell — only what GitHub Actions composite jobs need.
        devShells.ci = pkgs.mkShell {
          name = "caldera-tinyland-ci";
          packages = with pkgs; [
            python
            go_1_24
            nodejs_22
            nodePackages.pnpm
            libxml2.dev
            libxslt.dev
            xmlsec.dev
            pkg-config
            opentofu
            kubectl
            cosign
            skopeo
            just
            jq
            git
          ];
        };

        # Packages — the OCI image build target lands in a follow-up commit
        # (see Linear TIN-969). For now expose the formatter so CI can lint
        # the flake.
        packages = {
          # Re-export the formatter so tools like `nix run .#fmt` work.
          fmt = treefmtEval.config.build.wrapper;
        };

        formatter = treefmtEval.config.build.wrapper;

        checks = {
          formatting = treefmtEval.config.build.check self;

          statix = pkgs.runCommand "statix-check" { } ''
            ${pkgs.statix}/bin/statix check ${self}/flake.nix
            touch $out
          '';

          deadnix = pkgs.runCommand "deadnix-check" { } ''
            ${pkgs.deadnix}/bin/deadnix --fail ${self}/flake.nix
            touch $out
          '';
        };

        apps.default = {
          type = "app";
          program = "${pkgs.writeShellScript "caldera-info" ''
            cat <<EOF
            Caldera (Tinyland fork) — caldera.tinyland.dev

            Plan:        tinyland/docs/plan-onprem-saml.md
            Fork sync:   tinyland/docs/fork-sync-runbook.md
            SAML plugin: github.com/tinyland-inc/caldera-saml (v5-compat branch)

            Enter dev shell:   nix develop
            Run formatter:     nix fmt
            Validate flake:    nix flake check
            EOF
          ''}";
        };
      }
    );

  # Attic substituter — add these to nix.conf for cache hits during local builds:
  #
  #   extra-substituters = https://nix-cache.tinyland.dev
  #   extra-trusted-public-keys = main:eaUydxuDu7xBoy5cCo3MdknYAkVyTIASQ7DGuwxa+XA=
}
