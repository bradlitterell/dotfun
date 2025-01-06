# Fungible Dotfiles

This repository is intended to co-exist with either a `dotfiles` clone or a
`dropfiles` export of that. You can clone `dropfiles` for Fungible at Microsoft
via

``` bash
git clone git@github.com:SIGFUN/dropfiles.git $HOME/.dotfiles
git --git-dir=$HOME/.dotfiles --work-tree=$HOME checkout
git --git-dir=$HOME/.dotfiles --work-tree=$HOME config status.showUntrackedFiles no
```

and then cloning this repository via...

``` bash
git clone --bare git@github.com:SIGFUN/dotfun.git $HOME/.dotfun
git --git-dir=$HOME/.dotfun --work-tree=$HOME checkout drops
git --git-dir=$HOME/.dotfun --work-tree=$HOME config status.showUntrackedFiles no
```

It's important to check out the `drops` branch, since its HEAD is a commit that
removes all of my specific stuff and lets you create a Fungible configuration
file at `~/.dotgit/gitconfig_fungible` for use by `git-fix`. After that you
should be good to go.

## Another way

If you don't want to clone these repositories to an arbitrary location unrelated to $HOME, here is an alternative
clone script:

``` bash
TARGET=~/other_dotfiles
rm -rf $TARGET
git clone https://github.com/SIGFUN/dropfiles.git $TARGET/dotfiles
git clone https://github.com/SIGFUN/dotfun.git $TARGET/dotfun
git --git-dir=$TARGET/dotfiles/.git --work-tree=$TARGET/dotfiles checkout
git --git-dir=$TARGET/dotfiles/.git --work-tree=$TARGET/dotfiles config status.showUntrackedFiles no
git --git-dir=$TARGET/dotfun/.git --work-tree=$TARGET/dotfun checkout drops
git --git-dir=$TARGET/dotfun/.git --work-tree=$TARGET/dotfun config status.showUntrackedFiles no
```

## running under WSL

Running under WSL with Ubuntu 22., the shebang lines `#!/bin/bash -O extglobs` fails to parse and generates an error.
However, running the script with bash in a subshell seems to work.  Reason currently unknown.

``` bash
bash -O extglob ./damien_dotfiles/dotfun/bin/imaginarium /tmp/SbpQemuBootTestkgqizvjx/start_certificate.bin
```

Currently this generates some warnings, but seems to dump the certificate:

``` bash
getconf: Unrecognized variable `DARWIN_USER_TEMP_DIR'
ln: invalid option -- 'h'
Try 'ln --help' for more information.
```

## Global `gitconfig`

There is a global `gitconfig` in `.employer/gitconfig_global` with some handy
`insteadOf` remappings. This file is intended to be included in a top-level
`$HOME/.gitconfig` via the `include.path` configuration parameter.
