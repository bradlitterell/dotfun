# Fungible Dotfiles
This repository is intended to co-exist with either a `dotfiles` clone or a
`dropfiles` export of that. You can clone `dropfiles` for Fungible at Microsoft
via

```
$ git clone git@github.com:SIGFUN/dropfiles.git $HOME/.dotfiles
$ git --git-dir=$HOME/.dotfiles --work-tree=$HOME checkout
$ git --git-dir=$HOME/.dotfiles --work-tree=$HOME config status.showUntrackedFiles no
```

and then cloning this repository via...

```
$ git clone --bare git@github.com:SIGFUN/dotfun.git $HOME/.dotfun
$ git --git-dir=$HOME/.dotfun --work-tree=$HOME checkout drops
$ git --git-dir=$HOME/.dotfun --work-tree=$HOME config status.showUntrackedFiles no
```

It's important to check out the `drops` branch, since its HEAD is a commit that
removes all of my specific stuff and lets you create a Fungible configuration
file at `~/.dotgit/gitconfig_fungible` for use by `git-fix`. After that you
should be good to go.

## Global `gitconfig`
There is a global `gitconfig` in `.employer/gitconfig_global` with some handy
`insteadOf` remappings. This file is intended to be included in a top-level
`$HOME/.gitconfig` via the `include.path` configuration parameter.
