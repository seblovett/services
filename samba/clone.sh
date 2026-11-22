#!/bin/zsh
rsync -avh --progress --partial --no-o --no-g --exclude='.DS_Store' --exclude='._*' iot:/mnt/vol_share_seblo/share/ ~/smb/
