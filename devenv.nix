{ pkgs, ... }:

{
  packages = with pkgs; [
    bash
    git
    gh
    neovim
    stylua
  ];

  enterShell = ''
    export XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$PWD/.cache}"
    export XDG_STATE_HOME="''${XDG_STATE_HOME:-$PWD/.local/state}"
    export PR_REVIEW_GITSIGNS_ROOT="${pkgs.vimPlugins.gitsigns-nvim}"
    mkdir -p "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

    echo "pr-review.nvim dev shell ready: $(nvim --version | head -n 1)"
  '';

  scripts.validate.exec = ''
    bash scripts/validate.sh
  '';

  scripts.benchmark.exec = ''
    bash scripts/benchmark.sh
  '';

  tasks = {
    "dev:validate".exec = "validate";
    "dev:benchmark".exec = "benchmark";
    "dev:format".exec = "stylua lua plugin";
  };

  enterTest = ''
    validate
  '';
}
