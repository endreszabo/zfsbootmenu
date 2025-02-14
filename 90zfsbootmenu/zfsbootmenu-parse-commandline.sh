#!/bin/bash
# vim: softtabstop=2 shiftwidth=2 expandtab

# shellcheck disable=SC1091
. /lib/dracut-lib.sh

# Source options detected at build time
# shellcheck disable=SC1091
[ -r /etc/zfsbootmenu.conf ] && source /etc/zfsbootmenu.conf

# shellcheck disable=SC2154
if [ -n "${embedded_kcl}" ]; then
  mkdir -p /etc/cmdline.d/
  echo "${embedded_kcl}" > /etc/cmdline.d/zfsbootmenu.conf
fi

if [ -z "${BYTE_ORDER}" ]; then
  warn "unable to determine platform endianness; assuming little-endian"
  BYTE_ORDER="le"
fi

# Let the command line override our host id.
# shellcheck disable=SC2034
cli_spl_hostid=$( getarg spl.spl_hostid ) || cli_spl_hostid=$( getarg spl_hostid )
if [ -n "${cli_spl_hostid}" ] ; then
  # Start empty so only valid hostids are set for future use
  spl_hostid=

  # Test for decimal
  if (( 10#${cli_spl_hostid} )) >/dev/null 2>&1 ; then
    spl_hostid="$( printf "%08x" "${cli_spl_hostid}" )"
  # Test for hex. Requires 0x, if present, to be stripped
  # The change to cli_spl_hostid isn't saved outside of the test
  elif (( 16#${cli_spl_hostid#0x} )) >/dev/null 2>&1 ; then
    spl_hostid="${cli_spl_hostid#0x}"
    # printf will strip leading 0s if there are more than 8 hex digits
    # normalize to a maximum of 8, then run through printf to fill in
    # if there are fewer than 8 digits.
    spl_hostid="$( printf "%08x" "0x${spl_hostid:0:8}" )"
  # base 10 / base 16 tests fail on 0
  elif [ "${cli_spl_hostid#0x}" -eq "0" ] >/dev/null 2>&1 ; then
    spl_hostid=0
  # Not valid hex or dec, log
  else
    warn "ZFSBootMenu: invalid hostid value ${cli_spl_hostid}, ignoring"
  fi
fi

# Use the last defined console= to control menu output
control_term=$( getarg console )
if [ -n "${control_term}" ]; then
  control_term="/dev/${control_term%,*}"
  info "ZFSBootMenu: setting controlling terminal to: ${control_term}"
else
  control_term="/dev/tty1"
  info "ZFSBootMenu: defaulting controlling terminal to: ${control_term}"
fi

# Use loglevel to determine logging to /dev/kmsg
min_logging=4
loglevel=$( getarg loglevel )
if [ -n "${loglevel}" ]; then
  # minimum log level of 4, so we never lose error or warning messages
  [ "${loglevel}" -ge ${min_logging} ] || loglevel=${min_logging}
  info "ZFSBootMenu: setting log level from command line: ${loglevel}"
else
  loglevel=${min_logging}
fi

# hostid - discover the hostid used to import a pool on failure, assume it
# force  - append -f to zpool import
# strict - legacy behavior, drop to an emergency shell on failure

import_policy=$( getarg zbm.import_policy )
if [ -n "${import_policy}" ]; then
  case "${import_policy}" in
    hostid)
      if [ "${BYTE_ORDER}" = "be" ]; then
        info "ZFSBootMenu: invalid option for big endian systems"
        info "ZFSBootMenu: setting import_policy to strict"
        import_policy="strict"
      else
        info "ZFSBootMenu: setting import_policy to hostid matching"
      fi
      ;;
    force)
      info "ZFSBootMenu: setting import_policy to force"
      ;;
    strict)
      info "ZFSBootMenu: setting import_policy to strict"
      ;;
    *)
      info "ZFSBootMenu: unknown import policy ${import_policy}, defaulting to hostid"
      import_policy="hostid"
      ;;
  esac
elif getargbool 0 zbm.force_import -d force_import ; then
  import_policy="force"
  info "ZFSBootMenu: setting import_policy to force"
else
  info "ZFSBootMenu: defaulting import_policy to hostid"
  import_policy="hostid"
fi

# zbm.timeout= overrides timeout=
menu_timeout=$( getarg zbm.timeout -d timeout )
if [ -n "${menu_timeout}" ]; then
  info "ZFSBootMenu: setting menu timeout from command line: ${menu_timeout}"
elif getargbool 0 zbm.show ; then
  menu_timeout=-1;
  info "ZFSBootMenu: forcing display of menu"
elif getargbool 0 zbm.skip ; then
  menu_timeout=0;
  info "ZFSBootMenu: skipping display of menu"
else
  menu_timeout=10
fi

zbm_import_delay=$( getarg zbm.import_delay )
if [ "${zbm_import_delay:-0}" -gt 0 ] 2>/dev/null ; then
  # Again, this validates that zbm_import_delay is numeric in addition to logging
  info "ZFSBootMenu: import retry delay is ${zbm_import_delay} seconds"
else
  zbm_import_delay=5
fi

# Allow setting of console size; there are no defaults here
# shellcheck disable=SC2034
zbm_lines=$( getarg zbm.lines )
# shellcheck disable=SC2034
zbm_columns=$( getarg zbm.columns )

# Allow sorting based on a key
zbm_sort=
sort_key=$( getarg zbm.sort_key )
if [ -n "${sort_key}" ] ; then
  valid_keys=( "name" "creation" "used" )
  for key in "${valid_keys[@]}"; do
    if [ "${key}" == "${sort_key}" ]; then
      zbm_sort="${key}"
    fi
  done

  # If zbm_sort is empty (invalid user provided key)
  # Default the starting sort key to 'name'
  if [ -z "${zbm_sort}" ] ; then
    sort_key="name"
    zbm_sort="name"
  fi

  # Append any other sort keys to the selected one
  for key in "${valid_keys[@]}"; do
    if [ "${key}" != "${sort_key}" ]; then
      zbm_sort="${zbm_sort};${key}"
    fi
  done

  info "ZFSBootMenu: setting sort key order to ${zbm_sort}"
else
  zbm_sort="name;creation;used"
  info "ZFSBootMenu: defaulting sort key order to ${zbm_sort}"
fi

# shellcheck disable=SC2034
if [ "${BYTE_ORDER}" = "be" ]; then
  zbm_set_hostid=0
  info "ZFSBootMenu: big endian detected, disabling automatic replacement of spl_hostid"
elif getargbool 1 zbm.set_hostid ; then
  zbm_set_hostid=1
  info "ZFSBootMenu: enabling automatic replacement of spl_hostid"
else
  zbm_set_hostid=0
  info "ZFSBootMenu: disabling automatic replacement of spl_hostid"
fi

# rewrite root=
prefer=$( getarg zbm.prefer )
if [ -n "${prefer}" ]; then
  root="zfsbootmenu:POOL=${prefer}"
fi

wait_for_zfs=0
case "${root}" in
  ""|zfsbootmenu|zfsbootmenu:)
    # We'll take root unset, root=zfsbootmenu, or root=zfsbootmenu:
    root="zfsbootmenu"
    # shellcheck disable=SC2034
    rootok=1
    wait_for_zfs=1

    info "ZFSBootMenu: enabling menu after udev settles"
    ;;
  zfsbootmenu:POOL=*)
    # Prefer a specific pool for bootfs value, root=zfsbootmenu:POOL=zroot
    root="${root#zfsbootmenu:POOL=}"
    # shellcheck disable=SC2034
    rootok=1
    wait_for_zfs=1

    info "ZFSBootMenu: preferring ${root} for bootfs"
    ;;
esac

# Pool preference ending in ! indicates a hard requirement
bpool="${root%\!}"
if [ "${bpool}" != "${root}" ]; then
  # shellcheck disable=SC2034
  zbm_require_bpool=1
  root="${bpool}"
fi

# Make sure Dracut is happy that we have a root
if [ ${wait_for_zfs} -eq 1 ]; then
  ln -s /dev/null /dev/root 2>/dev/null
fi
