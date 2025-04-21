# ~/nix-packages/tmux-session-manager/default.nix
{ pkgs ? import <nixpkgs> { } }:

with pkgs;

stdenv.mkDerivation rec {
  # Make sure pname matches what you want the command to be called
  pname = "tms";
  version = "0.1.0"; # Or use a date like "2025-04-21"

  # *** CHANGE THIS LINE ***
  # Point src to the current directory containing the script and default.nix
  src = ./.;

  # No changes needed for buildInputs
  buildInputs = [
    bashInteractive
    tmux
    fzf
    gawk
    gnused
    coreutils
    findutils
    gnugrep
    git
    # neovim
    # lazygit
  ];

  # No changes needed for nativeBuildInputs
  nativeBuildInputs = [ makeWrapper bashInteractive ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin

    # *** CHANGE THIS LINE ***
    # Copy the script *from the source directory* to the destination.
    # IMPORTANT: Make sure 'tmux-session-manager.sh' below matches the ACTUAL filename of your script!
    cp ./sessionizer.sh $out/bin/${pname}

    chmod +x $out/bin/${pname}

    # Wrap the program (no changes needed here, assuming buildInputs are correct)
    wrapProgram $out/bin/${pname} --prefix PATH : ${
      lib.makeBinPath [
        bashInteractive
        tmux
        fzf
        gawk
        gnused
        coreutils
        findutils
        gnugrep
        git # neovim lazygit
      ]
    }

    runHook postInstall
  '';

  meta = with lib; {
    description =
      "A script to manage tmux sessions based on active sessions and project directories";
    homepage = "";
    license = licenses.mit; # Or your chosen license
    platforms = platforms.linux ++ platforms.darwin;
    maintainers = with maintainers; [ ];
  };
}

