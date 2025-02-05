# Nexus Media Install Script
# osm0sis @ xda-developers

# make sure variables are correct regardless of Magisk or recovery sourcing the script
[ -z $OUTFD ] && OUTFD=/proc/self/fd/$2 || OUTFD=/proc/self/fd/$OUTFD;
[ ! -z $ZIP ] && { ZIPFILE="$ZIP"; unset ZIP; }
[ -z $ZIPFILE ] && ZIPFILE="$3";

# Magisk Manager/booted flashing support
test -e /data/adb/magisk && adb=adb;
ps | grep zygote | grep -v grep >/dev/null && BOOTMODE=true || BOOTMODE=false;
$BOOTMODE || ps -A 2>/dev/null | grep zygote | grep -v grep >/dev/null && BOOTMODE=true;
if $BOOTMODE; then
  OUTFD=/proc/self/fd/0;
  dev=/dev;
  devtmp=/dev/tmp;
  if [ -e /data/$adb/magisk ]; then
    if [ ! -f /data/$adb/magisk_merge.img -a ! -e /data/adb/modules ]; then
      (/system/bin/make_ext4fs -b 4096 -l 64M /data/$adb/magisk_merge.img || /system/bin/mke2fs -b 4096 -t ext4 /data/$adb/magisk_merge.img 64M) >/dev/null;
    fi;
    test -e /magisk/.core/busybox && magiskbb=/magisk/.core/busybox;
    test -e /sbin/.core/busybox && magiskbb=/sbin/.core/busybox;
    test -e /sbin/.magisk/busybox && magiskbb=/sbin/.magisk/busybox;
    test "$magiskbb" && export PATH="$magiskbb:$PATH";
  fi;
fi;

ui_print() { $BOOTMODE && echo "$1" || echo -e "ui_print $1\nui_print" >> $OUTFD; }
show_progress() { echo "progress $1 $2" > $OUTFD; }
file_getprop() { grep "^$2=" "$1" | cut -d= -f2; }
set_perm() {
  uid=$1; gid=$2; mod=$3;
  shift 3;
  chown $uid:$gid "$@" || chown $uid.$gid "$@";
  chmod $mod "$@";
}
set_perm_recursive() {
  uid=$1; gid=$2; dmod=$3; fmod=$4;
  shift 4;
  until [ ! "$1" ]; do
    chown -R $uid:$gid "$1" || chown -R $uid.$gid "$1";
    find "$1" -type d -exec chmod $dmod {} +;
    find "$1" -type f -exec chmod $fmod {} +;
    shift;
  done;
}
payload_size_check() {
  reqSizeM=0;
  for entry in $(unzip -l "$@" 2>/dev/null | tail -n +4 | awk '{ print $1 }'); do
    test $entry != "--------" && reqSizeM=$((reqSizeM + entry)) || break;
  done;
  test $reqSizeM -lt 1048576 && reqSizeM=1 || reqSizeM=$((reqSizeM / 1048576));
}
target_size_check() {
  curBlocks=$(e2fsck -n $1 2>/dev/null | cut -d, -f3 | cut -d\  -f2);
  curUsedM=$((`echo "$curBlocks" | cut -d/ -f1` * 4 / 1024));
  curSizeM=$((`echo "$curBlocks" | cut -d/ -f2` * 4 / 1024));
  curFreeM=$((curSizeM - curUsedM));
}
mount_su() {
  test ! -e $mnt && mkdir -p $mnt;
  mount -t ext4 -o rw,noatime $suimg $mnt;
  for i in 0 1 2 3 4 5 6 7; do
    test "$(mount | grep " $mnt ")" && break;
    loop=/dev/block/loop$i;
    if [ ! -f "$loop" -o ! -b "$loop" ]; then
      mknod $loop b 7 $i;
    fi;
    losetup $loop $suimg && mount -t ext4 -o loop,noatime $loop $mnt;
  done;
}

ui_print " ";
ui_print "Nexus Media Systemless Installer Script";
ui_print "by osm0sis @ xda-developers";
ui_print " ";
modname=nexusmedia;
show_progress 1.34 2;

# default to hammerhead if none specified
media=bullhead;

# override zip filename parsing with a settings file
if [ -f /data/.$modname ]; then
  choice=$(cat /data/.$modname);
else
  choice=$(basename "$ZIPFILE");
fi;

# install based on name if present
case $choice in
  *hammerhead*) media=hammerhead;;
  *flo*|*deb*) media=flo;;
  *shamu*) media=shamu;;
  *volantis*) media=volantis;;
  *bullhead*) media=bullhead;;
  *angler*) media=angler;;
  *) ui_print "Warning: Invalid or no media choice found in filename, fallback to default!"; ui_print " ";;
esac;
ui_print "Using media directory: $media";

ui_print " ";
ui_print "Mounting...";
umount /system 2>/dev/null;
mount -o ro -t auto /system;
mount /data;
mount /cache;
test -f /system/system/build.prop && root=/system;

# Magisk clean flash support
if [ -e /data/$adb/magisk -a ! -e /data/$adb/magisk.img -a ! -e /data/adb/modules ]; then
  make_ext4fs -b 4096 -l 64M /data/$adb/magisk.img || mke2fs -b 4096 -t ext4 /data/$adb/magisk.img 64M;
fi;

# allow forcing a system installation regardless of su.img/magisk.img detection
case $(basename "$ZIPFILE") in
  *system*|*System*|*SYSTEM*) system=1; ui_print " "; ui_print "Warning: Forcing a system installation!";;
  *) suimg=`(ls /data/$adb/magisk_merge.img || ls /data/su.img || ls /cache/su.img || ls /data/$adb/magisk.img || ls /cache/magisk.img) 2>/dev/null`; mnt=$devtmp/$(basename $suimg .img);;
esac;
if [ "$suimg" ]; then
  mount_su;
  if [ ! -e /su/su.d/000mediamount -a ! -e /magisk/nexusmedia/module.prop -a ! -e /sbin/.core/img/nexusmedia/module.prop -a ! -e /sbin/.magisk/img/nexusmedia/module.prop -a "$(which e2fsck)" ]; then
    # make room for media which may not fit in su.img/magisk.img if there are other mods
    umount $mnt;
    payload_size_check "$ZIPFILE" "$media/*";
    target_size_check $suimg;
    if [ "$reqSizeM" -gt "$curFreeM" ]; then
      suNewSizeM=$((((reqSizeM + curUsedM) / 32 + 1) * 32));
      ui_print " ";
      ui_print 'Resizing su.img to '"$suNewSizeM"'M ...';
      e2fsck -yf $suimg;
      resize2fs $suimg "$suNewSizeM"M;
    fi;
    mount_su;
  fi;
  case $mnt in
    */magisk*) magisk=/$modname/system;;
  esac;
  target=$mnt$magisk;
else
  # SuperSU BINDSBIN support
  mnt=$(dirname `find /data -name supersu_is_here | head -n1` 2>/dev/null);
  if [ -e "$mnt" -a ! "$system" ]; then
    bindsbin=1;
    target=$mnt;
  elif [ -e "/data/adb/modules" -a ! "$system" ]; then
    mnt=/data/adb/modules_update;
    magisk=/$modname/system;
    target=$mnt$magisk;
  else
    mount -o rw,remount /system;
    mount /system;
    target=$root/system;
  fi;
fi;

ui_print " ";
ui_print "Extracting files...";
mkdir -p $dev/tmp/$modname;
cd $dev/tmp/$modname;
unzip -o "$ZIPFILE";
# work around old Magisk Manager PATH issue leading to toybox's limited tar being used
bb=$(which busybox 2>/dev/null);
case $media in
  hammerhead|flo) $bb tar -xJf common-5-7.tar.xz;;
  shamu|volantis) $bb tar -xJf common-6-9-5x-6p.tar.xz;;
  bullhead|angler) $bb tar -xJf common-6-9-5x-6p.tar.xz; $bb tar -xJf common-5x-6p.tar.xz;;
esac;
case $media in
  shamu|bullhead|angler) $bb tar -xJf common-6-5x-6p.tar.xz;;
esac;
$bb tar -xJf common.tar.xz;
$bb tar -xJf $media.tar.xz;

ui_print " ";
if [ -d common -a -d "$media" ]; then
  ui_print "Installing to $target/media ...";
  rm -rf $target/media;
  mkdir -p $target/media;
  cp -rf common/* $target/media/;
  cp -rf $media/* $target/media/;
else
  ui_print "Extraction error!";
  exit 1;
fi;
set_perm_recursive 0 0 755 644 $target/media;

if [ "$mnt" == "/su" -o "$bindsbin" ]; then
  ui_print " ";
  ui_print "Installing 000mediamount script to $mnt/su.d ...";
  cp -rf su.d/* $mnt/su.d;
  set_perm 0 0 755 $mnt/su.d/000mediamount;
elif [ "$magisk" ]; then
  ui_print " ";
  ui_print "Installing Magisk configuration files ...";
  sed -i "s/version=.*/version=${media}/g" module.prop;
  cp -f module.prop $mnt/$modname/;
  touch $mnt/$modname/auto_mount;
  touch $target/media/audio/.replace;
  # check Magisk version code to find if basic mount is supported and which method to use
  vercode=$(file_getprop /data/$adb/magisk/util_functions.sh MAGISK_VER_CODE 2>/dev/null);
  if [ "$vercode" -le 19001 ]; then
    mv -f $target/media/bootanimation.zip $mnt/$modname/bootanimation.zip;
    cp -f post-fs-data.sh $mnt/$modname/;
    serviced=`(ls -d /sbin/.core/img/.core/service.d || ls -d /sbin/.magisk/img/.core/service.d || ls -d /data/adb/service.d) 2>/dev/null`;
    cp -rf service.d/* $serviced;
    set_perm 0 0 755 $serviced/000mediacleanup;
    if [ "$vercode" -lt 1640 ]; then
      basicmnt="/cache/magisk_mount";
    else
      basicmnt="/data/adb/magisk_simple";
    fi;
    for i in $basicmnt; do
      mkdir -p $i/system/media;
      cp -rf $mnt/$modname/bootanimation.zip $i/system/media/;
    done;
  fi;
  chcon -hR 'u:object_r:system_file:s0' "$mnt/$modname";
  if $BOOTMODE; then
    test -e /magisk && imgmnt=/magisk || imgmnt=/sbin/.core/img;
    test -e /sbin/.magisk/img && imgmnt=/sbin/.magisk/img;
    test -e /data/adb/modules && imgmnt=/data/adb/modules;
    mkdir -p "$imgmnt/$modname";
    touch "$imgmnt/$modname/update";
    cp -f module.prop "$imgmnt/$modname/";
  fi;
elif [ -e $root/system/addon.d ]; then
  ui_print " ";
  ui_print "Installing 90-media.sh script to /system/addon.d ...";
  cp -rf addon.d/* $root/system/addon.d;
  set_perm 0 0 755 $root/system/addon.d/90-media.sh;
fi;

ui_print " ";
ui_print "Unmounting...";
test "$suimg" && umount $mnt;
test "$loop" && losetup -d $loop;
umount /system;
umount /data;
umount /cache;

cd /;
rm -rf /tmp/$modname /dev/tmp;
ui_print " ";
ui_print "Done!";
exit 0;
