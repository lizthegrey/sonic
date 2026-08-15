#!/bin/bash

# 检测是否是鲲鹏CPU
is_kunpeng_cpu() {
    if [ -f "/proc/cpuinfo" ]; then
        if grep -q "CPU part" "/proc/cpuinfo"; then
            local cpu_part=$(grep "CPU part" "/proc/cpuinfo" | head -1 | awk -F: '{print $2}' | tr -d ' ')
            if [ "$cpu_part" = "0xd02" ] || [ "$cpu_part" = "0xd06" ]; then
                return 0
            fi
        fi
    fi
    return 1
}

# LOCAL PATCH (not upstream): the original gate hard-checks Kunpeng 916/920
# CPU part IDs specifically, but the actual requirement this tool has is SVE
# support for goframe+SVE codegen. Rather than extend the vendor whitelist
# (Graviton3+, Cobalt, Axion, ...), check the real hardware capability:
# /proc/cpuinfo's "Features" line is the kernel's parsed HWCAP/HWCAP2,
# derived from the CPU's actual ID_AA64ZFR0_EL1/ID_AA64PFR0_EL1 capability
# registers at boot (userspace can't read those registers directly, so this
# is the standard portable way to query them on Linux).
has_sve() {
    if [ -f "/proc/cpuinfo" ]; then
        grep "^Features" /proc/cpuinfo | head -1 | grep -qw "sve"
    else
        return 1
    fi
}

check_kunpeng_cpu() {
    if is_kunpeng_cpu; then
        echo "检测到鲲鹏CPU"
    elif has_sve; then
        echo "检测到非鲲鹏SVE CPU（本地补丁放行）"
    else
        echo "不支持的CPU"
        exit 1
    fi
}
