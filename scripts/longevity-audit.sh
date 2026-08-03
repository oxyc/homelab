#!/usr/bin/env bash
# Longevity audit — READ-ONLY, writes nothing to disk (safe for a wear-conscious box).
# Reports SSD wear + lifetime writes, live write-rate per device, per-CT write
# attribution, and temperatures — the things that actually shorten hardware life.
#
# Run on the Proxmox host:
#   ssh root@<pve> 'bash -s' < scripts/longevity-audit.sh
# or copy it over and run locally. No cron, no persistent state — run on demand.
set -u

echo "== disks + layout =="
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL 2>/dev/null | grep -viE 'loop|^[[:space:]]*$'

echo
echo "== SSD wear + lifetime writes (the #1 longevity metric) =="
for d in $(lsblk -dno NAME 2>/dev/null | grep -E '^sd|^nvme'); do
  echo "-- /dev/$d --"
  smartctl -a "/dev/$d" 2>/dev/null | grep -iE \
    'Model|Power_On_Hours|Lifetime_Writes|Flash_Writes|Data Units Written|SSD_Life_Left|Percentage Used|Available Spare|Temperature_Cel|^Temperature:|Reallocated' \
    | sed 's/^/    /'
done

echo
echo "== live write rate by device (~6s sample) =="
s1=$(cat /proc/diskstats); sleep 6; s2=$(cat /proc/diskstats)
awk 'NR==FNR{w[$3]=$10; next} ($3 in w) && ($3 ~ /nvme|sd/){kb=($10-w[$3])*512/6/1024; if(kb>1) printf "  %-14s %9.1f KB/s written\n",$3,kb}' \
  <(echo "$s1") <(echo "$s2") | sort -k2 -rn
echo "  (near-zero here = the box is genuinely write-idle right now)"

echo
echo "== per-CT write attribution (cumulative this boot) =="
for ct in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
  p=$(ls /sys/fs/cgroup/lxc/"$ct"/io.stat /sys/fs/cgroup/lxc/"$ct"/*/io.stat 2>/dev/null | head -1)
  [ -n "$p" ] && awk -v ct="$ct" '{for(i=1;i<=NF;i++) if($i ~ /^wbytes=/){sub("wbytes=","",$i); s+=$i}} END{printf "  CT%s: %.1f GiB\n", ct, s/1073741824}' "$p"
done

echo
echo "== temperatures =="
for z in /sys/class/thermal/thermal_zone*; do
  t=$(cat "$z"/temp 2>/dev/null); ty=$(cat "$z"/type 2>/dev/null)
  [ -n "$t" ] && echo "  $ty: $((t/1000))C"
done
