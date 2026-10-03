# Agent instructions for ping-slave

This repo runs on the beacons (about 200 Pi Zero W). Every beacon update runs
`git fetch origin && git reset --hard origin/<branch>`, and a plain `git fetch` downloads every
branch. Anything pushed here, to any branch, ends up on every beacon over a shared uplink.

## Push rule

- Push only code and config, a few MB at most per push.
- Never push audio or light libraries, samples, images, or another repo's history. Not on any
  branch, not as an archive branch either.
- Before every push, measure what it adds and stop and ask if it is over ~5 MB or contains media files:

  ```sh
  git rev-list --objects origin/<branch>..HEAD | cut -d' ' -f1 \
    | git cat-file --batch-check='%(objectsize:disk)' | awk '{s+=$1} END {print s/1e6 " MB"}'
  ```

- A fresh `git clone` of this repo is about 500 KB. If it grows to many MB, find out why before the
  next beacon update.
