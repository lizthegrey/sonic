/*
 * Copyright 2026 ByteDance Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package sve decides whether this machine may run sonic's SVE natives.
//
// It lives apart from internal/native so that the sve_linkname and sve_wrapgoc
// packages can use it too. They cannot import internal/native, which imports
// them, and before this each carried its own private copy of the check in its
// test files -- copies that were never updated alongside the real one, so the
// tests gated on different hardware than the dispatcher did and skipped
// themselves on machines where the natives were live.
package sve

import (
	"bufio"
	"os"
	"strings"

	"github.com/shirou/gopsutil/cpu"
	xcpu "golang.org/x/sys/cpu"
)

// RequiredVectorLength is the SVE vector length, in bytes, that the natives
// require: 256-bit.
//
// This is not merely what asm2arm_tool was invoked with (--vl=32). The SVE
// kernels assume it. native/scanning.h reinterprets predicate registers as
// 32-bit lane masks -- get_maskx32 does
//
//	svbool_t cmp_pg = svcmpeq_n_u8(svptrue_b8(), v0, c);
//	uint32_t *bit7 = (uint32_t *)&cmp_pg;
//
// which yields 32 lane bits only when a vector is 32 bytes wide, while
// skip_string_fast advances s += 32 regardless. The SSE branch of that same
// function issues two 16-byte loads and combines them explicitly. So the port is
// written for 256-bit vectors rather than vector-length agnostically.
//
// Measured: on Graviton4 (Neoverse V2, 128-bit) skip_one_fast returns 31 where
// 42 is expected and -1 where 45 is expected, which surfaces downstream as
// "should always be valid json here". On Graviton3 (Neoverse V1, 256-bit) the
// full suite passes.
const RequiredVectorLength = 32

// Eligible reports whether this CPU may run the SVE natives.
//
// The CPU must implement SVE, and its vector length must be the width the
// kernels assume. Checking for SVE alone would be worse than the vendor list it
// replaces: it would enable these natives on Graviton4 and every other 128-bit
// implementation, where they silently corrupt output instead of failing.
//
// Ask the kernel rather than keeping a vendor list: x/sys/cpu decodes AT_HWCAP,
// which the kernel derives from ID_AA64PFR0_EL1 at boot. That picks up
// Graviton3, which the original Kunpeng part-id check excluded despite it
// working. That check is kept as a fallback for when the vector length cannot
// be established at all, so existing deployments cannot regress.
//
// Eligibility is not selection: sonic still requires SONIC_USE_SVE_WRAPGOC or
// SONIC_USE_SVE_LINKNAME before anything but neon is used.
func Eligible() bool {
	if xcpu.ARM64.HasSVE {
		if vl := VectorLength(); vl != 0 {
			return vl == RequiredVectorLength
		}
		// Vector length unknown; fall through to the legacy check.
	}
	return isKunpeng()
}

// Describe returns a short human-readable account of the decision, for tests
// and CI logs. A path that quietly falls back to neon looks identical to one
// that ran the natives, which is how the SVE breakage stayed hidden.
func Describe() string {
	var b strings.Builder
	b.WriteString("sve: ")
	if !xcpu.ARM64.HasSVE {
		b.WriteString("not implemented by this CPU")
	} else if vl := VectorLength(); vl == 0 {
		b.WriteString("present, vector length unknown")
	} else {
		b.WriteString("present, vector length ")
		b.WriteString(itoa(vl))
		b.WriteString(" bytes (natives require ")
		b.WriteString(itoa(RequiredVectorLength))
		b.WriteString(")")
	}
	if Eligible() {
		b.WriteString("; eligible")
	} else {
		b.WriteString("; NOT eligible, neon will be used")
	}
	return b.String()
}

func itoa(v int) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}

func isKunpeng() bool {
	cpuinfo, err := cpu.Info()
	if err == nil && len(cpuinfo) != 0 {
		if cpuinfo[0].Model == "0xd02" || cpuinfo[0].Model == "0xd06" {
			return true
		}
	}

	file, err := os.Open("/proc/cpuinfo")
	if err != nil {
		return false
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "CPU part") {
			parts := strings.SplitN(line, ":", 2)
			model := strings.TrimSpace(parts[1])
			if model == "0xd02" || model == "0xd06" {
				return true
			}
		}
	}
	return false
}
