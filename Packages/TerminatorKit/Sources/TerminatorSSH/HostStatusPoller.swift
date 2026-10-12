import Foundation
import TerminatorCore

enum HostStatusScript {
    static let command = """
    export PATH="/usr/sbin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
    if [ -r /proc/stat ]; then
      awk '{printf "UPTIME %s\\n", $1; exit}' /proc/uptime
      awk '{printf "LOAD %s %s %s\\n", $1, $2, $3; exit}' /proc/loadavg
      awk '/^MemTotal/ {t=$2*1024} /^MemAvailable/ {a=$2*1024} /^SwapTotal/ {st=$2*1024} /^SwapFree/ {sf=$2*1024} /^Buffers/ {b=$2*1024} /^Cached:/ {c=$2*1024} END {u=t-a; if (u<0) u=0; su=st-sf; if (su<0) su=0; printf "MEM %d %d %d %d %d %d\\n", t, u, a, st, su, b+c}' /proc/meminfo
      if df -PT -B1 / >/dev/null 2>&1; then
        df -PT -B1 2>/dev/null | awk 'NR>1 {
          kind=$2
          if (kind ~ /tmpfs|devtmpfs|squashfs|overlay|proc|sysfs|cgroup|devpts|efivarfs|bpf|tracefs|nsfs|autofs/) next
          mount=$7
          for (i=8; i<=NF; i++) mount=mount " " $i
          name=$1
          sub(/^.*\\//, "", name)
          printf "DISK\\t%s\\t%s\\t%s\\t%s\\t0\\t0\\t%s\\n", name, kind, $3, $4, mount
        }'
      else
        df -kP 2>/dev/null | awk 'NR>1 {
          if ($1 ~ /^(tmpfs|devtmpfs|overlay|udev|none|shm)$/) next
          name=$1
          sub(/^.*\\//, "", name)
          mount=$6
          for (i=7; i<=NF; i++) mount=mount " " $i
          printf "DISK\\t%s\\t\\t%.0f\\t%.0f\\t0\\t0\\t%s\\n", name, $2*1024, $3*1024, mount
        }'
      fi
      ps -eo pid=,pcpu=,rss=,user=,comm= --sort=-pcpu 2>/dev/null | awk 'NR<=40 && NF>=5 {
        name=$5
        for (i=6; i<=NF; i++) name=name " " $i
        printf "PROC\\t%s\\t%s\\t%.0f\\t0\\t0\\t%s\\t%s\\n", $1, $2, $3*1024, $4, name
      }'
      awk '
        function snap(cpu, disk, net,    line, n, i, f, total, idle, name, rx, tx) {
          while ((getline line < "/proc/stat") > 0) {
            if (line ~ /^cpu/) {
              n = split(line, f)
              total = 0
              for (i = 2; i <= n; i++) total += f[i] + 0
              idle = (n >= 5 ? f[5] + 0 : 0) + (n >= 6 ? f[6] + 0 : 0)
              cpu[f[1]] = total SUBSEP idle
            }
          }
          close("/proc/stat")
          while ((getline line < "/proc/diskstats") > 0) {
            n = split(line, f)
            if (n >= 10) disk[f[3]] = (f[6] + 0) SUBSEP (f[10] + 0)
          }
          close("/proc/diskstats")
          rx = 0; tx = 0
          while ((getline line < "/proc/net/dev") > 0) {
            if (index(line, ":") == 0) continue
            split(line, f, ":")
            name = f[1]
            gsub(/ /, "", name)
            if (name == "lo" || name == "") continue
            n = split(f[2], f)
            irx = f[1] + 0
            itx = (n >= 9 ? f[9] + 0 : 0)
            rx += irx
            tx += itx
            net["i:" name] = irx SUBSEP itx
          }
          close("/proc/net/dev")
          net["rx"] = rx
          net["tx"] = tx
        }
        BEGIN {
          snap(a, ad, an)
          system("sleep 0.25")
          snap(b, bd, bn)
          for (key in b) {
            if (!(key in a)) continue
            split(a[key], pa, SUBSEP)
            split(b[key], pb, SUBSEP)
            dt = pb[1] - pa[1]
            di = pb[2] - pa[2]
            pct = (dt > 0) ? (100 * (dt - di) / dt) : 0
            if (pct < 0) pct = 0
            if (pct > 100) pct = 100
            printf "CORE %s %.1f\\n", key, pct
          }
          for (key in bd) {
            if (!(key in ad)) continue
            split(ad[key], pa, SUBSEP)
            split(bd[key], pb, SUBSEP)
            dr = (pb[1] - pa[1]) * 512 / 0.25
            dw = (pb[2] - pa[2]) * 512 / 0.25
            if (dr < 0) dr = 0
            if (dw < 0) dw = 0
            printf "DISKRATE %s %.0f %.0f\\n", key, dr, dw
          }
          rx = (bn["rx"] - an["rx"]) / 0.25
          tx = (bn["tx"] - an["tx"]) / 0.25
          if (rx < 0) rx = 0
          if (tx < 0) tx = 0
          printf "NET %.0f %.0f\\n", rx, tx
          for (key in bn) {
            if (index(key, "i:") != 1) continue
            if (!(key in an)) continue
            split(an[key], pa, SUBSEP)
            split(bn[key], pb, SUBSEP)
            drx = (pb[1] - pa[1]) / 0.25
            dtx = (pb[2] - pa[2]) / 0.25
            if (drx < 0) drx = 0
            if (dtx < 0) dtx = 0
            printf "NIC %s %.0f %.0f\\n", substr(key, 3), drx, dtx
          }
        }
      '
      awk '/^MemTotal/ {t=$2*1024} /^MemAvailable/ {a=$2*1024} /^SwapTotal/ {st=$2*1024} /^SwapFree/ {sf=$2*1024} /^Buffers/ {b=$2*1024} /^Cached:/ {c=$2*1024} END {u=t-a; if (u<0) u=0; su=st-sf; if (su<0) su=0; printf "MEM %d %d %d %d %d %d\\n", t, u, a, st, su, b+c}' /proc/meminfo
      awk '{printf "UPTIME %s\\n", $1; exit}' /proc/uptime
      awk '{printf "LOAD %s %s %s\\n", $1, $2, $3; exit}' /proc/loadavg
    else
      boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \\([0-9][0-9]*\\).*/\\1/p')
      now=$(date +%s)
      if [ -n "$boot" ]; then echo "UPTIME $((now - boot))"; else echo "UPTIME 0"; fi
      sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); printf "LOAD %s %s %s\\n", $1, $2, $3}'
      ncpu=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
      ps -A -o pcpu= 2>/dev/null | awk -v n="$ncpu" '{s+=$1} END {if (n<1) n=1; p=s/n; if (p>100) p=100; printf "CORE cpu %.1f\\n", p+0}'
      pagesize=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
      total=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
      vm_stat | awk -v page="$pagesize" -v total="$total" '
        /Pages free/ {free=$3} /Pages inactive/ {inactive=$3} /Pages speculative/ {spec=$3} /Pages occupied by compressor/ {comp=$5}
        /File-backed pages/ {file=$3}
        END {
          gsub(/\\./, "", free); gsub(/\\./, "", inactive); gsub(/\\./, "", spec); gsub(/\\./, "", comp); gsub(/\\./, "", file)
          avail=(free+inactive+spec)*page
          cached=(file+0)*page
          used=total-avail
          if (used<0) used=0
          printf "MEM %.0f %.0f %.0f 0 0 %.0f\\n", total, used, avail, cached
        }'
      swap=$(sysctl -n vm.swapusage 2>/dev/null)
      printf '%s\n' "$swap" | awk 'function bytes(s,    n, u) {
        n = 0
        if (match(s, /[0-9.]+/)) n = substr(s, RSTART, RLENGTH) + 0
        u = substr(s, RSTART + RLENGTH, 1)
        if (u == "K") return n * 1024
        if (u == "M") return n * 1024 * 1024
        if (u == "G") return n * 1024 * 1024 * 1024
        if (u == "T") return n * 1024 * 1024 * 1024 * 1024
        return n
      }
      {
        t = 0
        u = 0
        for (i = 1; i <= NF; i++) {
          if ($i == "total") t = bytes($(i+2))
          if ($i == "used") u = bytes($(i+2))
        }
        printf "SWAP %.0f %.0f\\n", t, u
      }'
      df -kP 2>/dev/null | awk 'NR>1 {
        if ($1 ~ /^(devfs|map|tmpfs)$/) next
        name=$1; sub(/^.*\\//, "", name)
        printf "DISK\\t%s\\t%s\\t%.0f\\t%.0f\\t0\\t0\\t%s\\n", name, "apfs", $2*1024, $3*1024, $6
      }'
      nic1=$(netstat -ibn 2>/dev/null | awk 'NR>1 && $3 ~ /<Link/ && $1 != "lo0" {printf "%s %.0f %.0f\\n", $1, $7, $10}')
      rx1=$(printf '%s\\n' "$nic1" | awk '{rx+=$2} END {printf "%.0f", rx+0}')
      tx1=$(printf '%s\\n' "$nic1" | awk '{tx+=$3} END {printf "%.0f", tx+0}')
      sleep 0.25
      nic2=$(netstat -ibn 2>/dev/null | awk 'NR>1 && $3 ~ /<Link/ && $1 != "lo0" {printf "%s %.0f %.0f\\n", $1, $7, $10}')
      rx2=$(printf '%s\\n' "$nic2" | awk '{rx+=$2} END {printf "%.0f", rx+0}')
      tx2=$(printf '%s\\n' "$nic2" | awk '{tx+=$3} END {printf "%.0f", tx+0}')
      printf '%s\\n---\\n%s\\n' "$nic1" "$nic2" | awk '$0=="---"{p=1; next} NF>=3 { if (!p) {rx[$1]=$2; tx[$1]=$3; next} d=($2-rx[$1])/0.25; e=($3-tx[$1])/0.25; if (d<0) d=0; if (e<0) e=0; printf "NIC %s %.0f %.0f\\n", $1, d, e }'
      awk -v a="$rx1" -v b="$rx2" -v c="$tx1" -v d="$tx2" 'BEGIN {rx=(b-a)/0.25; tx=(d-c)/0.25; if (rx<0) rx=0; if (tx<0) tx=0; printf "NET %.0f %.0f\\n", rx, tx}'
      ps -axo pid=,pcpu=,rss=,user=,comm= 2>/dev/null | awk 'NR<=25 && NF>=5 {
        name=$5; for (i=6; i<=NF; i++) name=name " " $i
        printf "PROC\\t%s\\t%s\\t%.0f\\t0\\t0\\t%s\\t%s\\n", $1, $2, $3*1024, $4, name
      }'
    fi
    """
}

actor HostStatusPoller {
    private let coordinator: NIOSSHConnectionCoordinator
    private let publish: @Sendable (HostStatusSnapshot) async -> Void
    private var task: Task<Void, Never>?

    init(
        coordinator: NIOSSHConnectionCoordinator,
        publish: @escaping @Sendable (HostStatusSnapshot) async -> Void
    ) {
        self.coordinator = coordinator
        self.publish = publish
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.collect()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func collect() async {
        let hostIDs = await coordinator.activePoolHostIDs()
        await withTaskGroup(of: Void.self) { group in
            for hostID in hostIDs {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.poll(hostID)
                }
            }
        }
    }

    private func poll(_ hostID: UUID) async {
        guard let result = try? await coordinator.exec(
            hostID: hostID,
            command: HostStatusScript.command,
            timeout: .seconds(8),
            partialOnTimeout: true
        ), let snapshot = HostStatusReport.parse(result.stdout, hostID: hostID) else { return }
        await publish(snapshot)
    }
}
