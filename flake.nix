{
  description = "simple OSX KVM";

  inputs.nixpkgs.url = "nixpkgs/21.05";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.osx-kvm.url = "github:foxlet/macOS-Simple-KVM";
  inputs.osx-kvm.flake = false;

  outputs = { self, nixpkgs, flake-utils, osx-kvm }:

    flake-utils.lib.eachDefaultSystem (system:
      let
        lib = nixpkgs.lib;

        pkgs = nixpkgs.legacyPackages.${system};

        fetchMacOS = pkgs.stdenv.mkDerivation {
          name = "fetchMacOS";
          buildInputs = [
            (pkgs.python38.withPackages (pyPkgs: with pyPkgs; [ requests click ]))
          ];
          unpackPhase = "true";
          installPhase = ''
            mkdir -p $out/bin
            cp ${osx-kvm}/tools/FetchMacOS/fetch-macos.py $out/bin/fetchMacOS
            chmod +x $out/bin/fetchMacOS
          '';
        };

        start =
          pkgs.writeShellScriptBin "start" ''
            set -e

            # Prefix PATH with utilities required
            PATH="${lib.makeBinPath (with pkgs; [
              coreutils
              jq
              qemu
            ])}''${PATH:+:}''${PATH-}"
            export PATH

            if [ ! -e disk0.qcow2 ];then
              ${self.packages.${system}.init}/bin/init
            fi

            cp ${osx-kvm}/firmware/OVMF_VARS-1024x768.fd OVMF_VARS.fd
            cp ${osx-kvm}/ESP.qcow2 .
            chmod a+w OVMF_VARS.fd
            chmod a+w ESP.qcow2

            ramSize="$(jq -r '.ramSize' settings.json)"; export ramSize
            cores="$(jq -r '.cores' settings.json)"; export cores
            headless="$(jq -r '.headless' settings.json)"; export headless

            declare -a headlessCommandArray=()
            if [ "$headless" == "true" ]; then
              headlessCommandArray=( -nographic -vnc :0 -k en-us )
            fi

            qemu-system-x86_64 \
              -enable-kvm \
              -m "$ramSize" \
              -machine q35,accel=kvm \
              -smp $(( "$cores" * 2 )),cores="$cores" \
              -cpu Penryn,vendor=GenuineIntel,kvm=on,+sse3,+sse4.2,+aes,+xsave,+avx,+xsaveopt,+xsavec,+xgetbv1,+avx2,+bmi2,+smep,+bmi1,+fma,+movbe,+invtsc \
              -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" \
              -smbios type=2 \
              -drive if=pflash,format=raw,readonly=on,file="${osx-kvm}/firmware/OVMF_CODE.fd" \
              -drive if=pflash,format=raw,file="OVMF_VARS.fd" \
              -vga qxl \
              -device ich9-intel-hda -device hda-output \
              -usb -device usb-kbd -device usb-mouse \
              -netdev user,id=net0 \
              -device e1000-82545em,netdev=net0,id=net0,mac=52:54:00:c9:18:27 \
              -device ich9-ahci,id=sata \
              -drive id=ESP,if=none,format=qcow2,file=ESP.qcow2 \
              -device ide-hd,bus=sata.2,drive=ESP \
              -drive id=InstallMedia,format=raw,if=none,file=BaseSystem.img \
              -device ide-hd,bus=sata.3,drive=InstallMedia \
              -drive id=SystemDisk,if=none,file=disk0.qcow2 \
              -device virtio-blk,drive=SystemDisk \
              "''${headlessCommandArray[@]}" \
          '';

        init = pkgs.writeShellScriptBin "init" ''
          set -e

          # Prefix PATH with utilities required
          PATH="${lib.makeBinPath (with pkgs; [
            coreutils
            dmg2img
            jq
            moreutils
            qemu
          ])}''${PATH:+:}''${PATH-}"
          export PATH

          if [ -e disk0.qcow2 ]; then
            echo "The current directory already contains disk0.qcow2. Delete it first!"
            exit 1
          fi

          # get settings from user input
          echo "choose disk size (example: 64G)" && echo -n "answer: "
          read -r diskSize
          echo "choose ram size (example: 6G)" && echo -n "answer: "
          read -r ramSize
          echo "choose number of cpu cores (example: 2)" && echo -n "answer: "
          read -r cores
          echo "choose MacOS version (example: 10.15) (leave empty for latest)" && echo -n "answer: "
          read -r osVersion

          echo "{}" > settings.json
          jq ".ramSize = \"$ramSize\"" settings.json | sponge settings.json
          jq ".cores = \"$cores\"" settings.json | sponge settings.json
          jq ".headless = \"false\"" settings.json | sponge settings.json

          if [ -z "$osVersion" ]; then
            ${fetchMacOS}/bin/fetchMacOS
          else
            ${fetchMacOS}/bin/fetchMacOS -v "$osVersion"
          fi
          dmg2img ./BaseSystem/BaseSystem.dmg ./BaseSystem.img
          rm -r ./BaseSystem

          qemu-img create -f qcow2 disk0.qcow2 "$diskSize"
        '';

        tests-with-shellcheck = lib.mapAttrs' (name: value: lib.nameValuePair
          ("test-shellcheck-" + name)
          (pkgs.runCommandLocal ("test-shellcheck-" + name) {
            nativeBuildInputs = with pkgs; [
              shellcheck
            ];
          } ''
            set -eu -o pipefail
            shellcheck "${value}/bin/${name}"
            touch "$out"
          '')
        ) (removeAttrs self.packages.${system} [ "default" ]);
      in
      {
        packages = {
          inherit start init;
          default = start;
        };

        checks = tests-with-shellcheck;
      });
}
