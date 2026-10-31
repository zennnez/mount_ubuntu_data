##########################################################################################
# Mount Ubuntu Data - KernelSU / Magisk installer
# Author: zen
##########################################################################################

SKIPUNZIP=0

# A zip packed or edited on Windows keeps CR on every line. Android sh then dies with
# "syntax error: unexpected end of file" / "$'\r': command not found" and the module
# will not flash. Strip CR and a UTF-8 BOM before any script is executed.
fix_crlf() {
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" > "$1.lf" || return 0
  cat "$1.lf" > "$1" || return 0
  rm -f "$1.lf"
  _h=$(head -c 3 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n' || true)
  if [ "$_h" = "efbbbf" ]; then
    tail -c +4 "$1" > "$1.lf" && cat "$1.lf" > "$1" && rm -f "$1.lf"
  fi
  return 0
}

fix_crlf "$MODPATH/ubuntu-data.sh"
fix_crlf "$MODPATH/service.sh"
fix_crlf "$MODPATH/action.sh"
fix_crlf "$MODPATH/uninstall.sh"
fix_crlf "$MODPATH/ubuntu/setup-sharing.sh"
fix_crlf "$MODPATH/module.prop"
fix_crlf "$MODPATH/sepolicy.rule"

# version comes from module.prop, so it can not drift again
_ver=$(grep -m1 '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2)
ui_print "Mount Ubuntu Data  ${_ver:-}"

# repo files that must not end up on the device
rm -f "$MODPATH/.gitattributes" "$MODPATH/.editorconfig" "$MODPATH/pack.py"

# stop any running daemon from earlier versions so new scripts take effect immediately
pkill -f "ubuntu-data.sh.*daemon" 2>/dev/null || true

ui_print "- Setting permissions..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/ubuntu-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/ubuntu/setup-sharing.sh" 0 0 0755

# create config.sh once; an existing one (your edits) is kept
sh "$MODPATH/ubuntu-data.sh" init-config

ui_print "- Looking for the partition (/dev/block/by-name/<PART_NAME>)..."
sh "$MODPATH/ubuntu-data.sh" layout 2>/dev/null | while read -r l; do ui_print "  $l"; done

ui_print "- Support: t.me/kokernel"
ui_print "- Author: t.me/zennnez"
