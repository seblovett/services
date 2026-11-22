#!/bin/zsh
/opt/homebrew/bin/rsync -avh --partial --update --chown=1100:1100 --chmod=D2770,F660 --exclude='.DS_Store' --exclude='._*' ~/smb/ iot:/mnt/vol_share_seblo/share/
