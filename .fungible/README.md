# Damien's Fungible Dotfiles
This project is meant to be cloned into a bare repository with a separate work
tree in your home directory. It is used in conjunction with the tooling in my
personal dotfiles repository, which is not publicly-hosted.

```
$ git clone --bare https://github.com/SIGFUN/dotfun.git .dotfun
$ git --git-dir=$HOME/.dotfun config --local status.showUntrackedFiles no
$ git --git-dir=$HOME/.dotfun --work-tree=$HOME checkout
```

Some documentation for this type of flow is available
[here](https://www.atlassian.com/git/tutorials/dotfiles).

The repo has a `.employer` symlink that the dotfiles can rely on to include
employer-specific content, like git-config(7) files.
