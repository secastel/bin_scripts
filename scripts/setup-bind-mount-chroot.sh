#!/bin/sh

# @autogenerated_warning@
# @autogenerated_timestamp@
# @PACKAGE@ @VERSION@
# @PACKAGE_URL@

COPYRIGHT="
Copyright (C) 2017 A. Gordon (assafgordon@gmail.com)
License: GPLv3+
"

# Chroot Directory Boot-Strapper
#
# Copyright (C) 2017 Assaf Gordon <assafgordon@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


##
## Functions start here
##

set -eu

show_help_and_exit()
{
    BASE=$(basename "$0")
    echo \
"bind-mount-chroot-setup - Creates a bind-mounted directory for easier chroot
Version: @VERSION@
$COPYRIGHT
See: @PACKAGE_URL@

Usage: $BASE [OPTIONS] -b DIR

Options:
  -b DIR = Base directory for the chroot (required).
           Will be created if needed.
  -h     = This help screen.
  -H     = Longer help script more details.
  -L     = Do not add default list of directories (/bin,/usr,/lib,/lib64)
  -n     = dry run: print but do not execute commands.
  -r SRC = Bind-Mount SRC (DIR or FILE) read-only in base-dir.
           SRC must exist on the host file system.
           if SRC is a character device, it will be created (not bind-mounted).
  -u     = Unmount (instead of default mount). Only -b is needed.
  -v     = print actions to STDOUT.
  -w SRC = Bind-Mount SRC read-write in base-dir.

Use this script to create a directory that can be easily used as a
chroot directory while exposing the host's filesystem (mostly as
read-only directories).

Example:

  $BASE -b /var/my-chroot -w /tmp

"

    if test "$1" = long ; then
        echo \
"The above command:
1) creates /var/my-chroot
2) bind-mounts /bin,/lib,/lib64,/usr onto
    /var/my-chroot/{bin,lib,lib64,usr} as
   read-only mounts with nosuid,nodev options.
3) bind-mounts /tmp as /var/my-chroot/tmp (writeable).

chrooting into it with:

   chroot /var/my-chroot /bin/bash -il

For even greater restrictions, consider:

   unshare -n \\
     setpriv --no-new-privs \\
           --inh-caps -all,+sys_chroot,+setgid,+setuid \\
           --bounding-set -all,+sys_chroot,+setgid,+setuid \\
       chroot --userspec nobody:nobody /var/my-chroot /bin/bash -il

The goals for this scripts are:

1) To easily  expose the same file-system structure as the host,
   with nosuid,nodev for greater security,
   and without /proc,/dev (on purpose).

2) This is especially useful for python/perl scripts
   which might require lots of dependencies from /usr
   or /usr/local .

3) This script should be consider a stop-gap solution
   before a fully-functional container is setup.

4) It is useful when needing to work with another daemon
  that supports 'chroot' but no other containment features.

Notes:
5) It is safe to run this script again with same parameters,
   it will not remount again over an existing mount
   (or fail with '-u' if nothing is mounted).

6) To understand what commands are used, use '-n', e.g.:

     $BASE -b /var/my-chroot -n

7) When mounting a single file (-r FILE/-w FILE),
   updates to the file on the host might not be reflected
   inside the chroot - if the text-editor replaces the file
   instead of modifying it inplace, because the chroot is using
   the inode of the old/deleted copy.
"
    fi

    exit 0
}


log()
{
    if test "$verbose" ; then
        echo "$1"
    fi
}

die()
{
    BASE=$(basename "$0")
    echo "$BASE: error: $*" >&2
    exit 1
}


create_chroot_base_dir()
{
    log "creating and bind-mouting base dir '$1'"

    $dry mkdir -p "$1"

    # bind-mount the directory to itself (if not already mounted)
    # this prevents hard-linking to any file above it
    # (and escaping the chroot)

    _a=$(findmnt --list --noheadings -o TARGET,FSROOT "$1" \
                | awk '$1==$2 { print $1}')
    if test "$1" != "$_a" ; then
        # Mount it on itself
        $dry mount --bind "$1" "$1"
    else
        # Already mounted on itself,
        # turn it read-write so we can make changes
        $dry mount -o bind,remount,rw "$1"
    fi
}

make_basedir_ro()
{
    log "making base dir '$1' read-only"
    $dry mount -o bind,remount,ro "$1"
}


validate_input_list()
{
    for src in $list ;
    do
        # Remove 'rw:' label (if any)
        if expr "$src" : "^rw:" >/dev/null 2>&1 ; then
            src=${src#rw:}
        fi

        expr "$src" : "/" 1>/dev/null 2>&1 \
            || die "bind-mount source '$src' does not start with slash"

        test -e "$src" || die "bind-mount source '$src' does not exist"

        # Ensure it's a supported file type
        if test -d "$src" ; then
	    :
        elif test -f "$src" ; then
	    :
        elif test -c "$src" ; then
	    :
        else
            die "invalid source '$src': not a directory/file/char-dev"
        fi
    done
}

is_mounted()
{
    findmnt --list --noheadings "$1" >/dev/null
}


mount_list()
{
    for src in $list ;
    do
        mount_mode=ro # default: read-only

        # Remove 'rw:' label (if any)
        if expr "$src" : "^rw:" >/dev/null 2>&1 ; then
            src=${src#rw:}
            mount_mode=rw
        fi

        dst=${basedir}${src}

        if is_mounted "$dst" ; then
            log "'$src' already bind-mounted on '$dst' - skipping."
            continue
        fi

        if test -d "$src" ; then
            # If a directory, create it under chroot
            # then bind it.
            log "bind-mounting directory '$src' on '$dst' ($mount_mode)"
            $dry mkdir -p "$dst"
            $dry mount --bind "$src" "$dst"
            $dry mount -o bind,remount,$mount_mode,nosuid,nodev "$dst"

        elif test -f "$src" ; then
            # If a file, create an empty file under chroot,
            # then bind it.
            b=$(dirname "$src")
            log "bind-mounting file '$src' on '$dst' ($mount_mode)"
            $dry mkdir -p "${basedir}${b}"
            $dry touch "$dst"
            $dry mount --bind "$src" "$dst"
            $dry mount -o bind,remount,nosuid,nodev,$mount_mode "$dst"

        elif test -c "$src" ; then

            # only create if not already there
            if ! test -c "$dst" ; then

                # If a character device, recreate it
                b=$(dirname "$src")
                $dry mkdir -p "${basedir}${b}"

                # Get device details
                dev_num=$(stat -c "0x%t 0x%T" "$src")
                perm=$(stat -c "0%a" "$src")
                own=$(stat -c '%g:%u' "$src")

                # Recreate the device
                log "creating char-dev file '$dst' with major/minor $dev_num " \
                    "permission $perm"
                $dry mknod -m "$perm" "$dst" c $dev_num
                $dry chown "$own" "$dst"
            else
                log "char-dev '$dst' already exists - skipping "
            fi
        else
            # Should never happen - 'validate_input_list' should've caught it
            die "internal error"
        fi

    done
}



unmount_list()
{
    test -d "$1" || die "invalid base directory '$1'"

    # Unmount any bind-mounted directory under the chroot base-dir.
    # The '/' in grep ensures the base directory itself is not included.
    for src in $(findmnt -o TARGET --list | sed -e 's;//*;/;' -e 's;/$;;' \
                        | grep "^$1/" ) ;
    do
        log "unmounting directory '$src'"
        $dry umount -- "$src"
    done

    # If the base directory is bind-mounted to itself, unmount it
    _a=$(findmnt --list --noheadings -o TARGET,FSROOT "$1" \
                | awk '$1==$2 { print $1}')
    if test "$1" = "$_a" ; then
        log "unmounted base chroot directory '$1'"
        $dry umount "$1"
    else
        log "base chroot directory '$1' not self-bind-mounted - skipping"
    fi
}


##
## Script starts here
##

default_list="
/bin
/usr
/lib
/dev/null
/dev/zero
"

if test -d "/lib64" ; then
    # not all systems have this
    default_list="$default_list /lib64"
fi

list=
show_help=
long_help=
verbose=
dry=
action=mount
basedir=
no_default_list=

# Parse parameters
while getopts Hhvnub:Lr:w: param
do
    case $param in
        b)   basedir="$OPTARG";;
        H)   long_help=1;;
        h)   show_help=1;;
        v)   verbose=1;;
        n)   dry=echo;;
        r)   list="$list $OPTARG";;
        w)   list="$list rw:$OPTARG";;
        L)   no_default_list=1;;
        u)   action=unmount;;
        ?)   die "unknown/invalid command line option";;
    esac
done
shift $(($OPTIND - 1))

test -n "$long_help" && show_help_and_exit long
test -n "$show_help" && show_help_and_exit short
test -n "$basedir" || die "missing base chroot directory (-b DIR)"
basedir=$(echo "$basedir" | sed 's;//*$;;')

if test "$action" = "unmount" && test -n "$list" ; then
    die "unmount option does not take -r/-w options"
fi
if test -z "$no_default_list" ; then
    list="$default_list $list"
fi


if test "$action" = "mount" ; then
    validate_input_list
    create_chroot_base_dir "$basedir"
    mount_list
    make_basedir_ro "$basedir"
else
    unmount_list "$basedir"
fi