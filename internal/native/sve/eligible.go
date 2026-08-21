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

// The SVE vector lengths, in bytes, that each flavour of native supports.
//
// Two independent things have to line up for a vector length to work.
//
// The kernels must compute the right answer at that width. They originally did
// not: native/scanning.h read predicate registers as fixed 32-bit lane masks,
// so it was correct only at 32 bytes. That is now expressed vector-length
// agnostically in native/sve_compat.h, so the results are right at any width.
//
// And the frame metadata handed to Go must match, because scalable spill slots
// are VL bytes wide. Get that wrong and results are still correct but unwinding
// is not: Go computes the wrong caller SP, so a fault inside a native cannot be
// recovered and precise GC stack scanning walks the wrong frame.
//
// sve_wrapgoc loads through internal/loader, so its frame metadata is ordinary
// Go data; it carries one pcsp table per width and picks at load time.
//
// sve_linkname is statically linked and its frame sizes live in the TEXT
// directives of generated Go assembly (NOSPLIT, $80 vs $64), fixed when the
// package is built. Supporting a second width there needs a second set of
// symbols, so it stays at the width it was built for.
var WrapgocVectorLengths = [...]int{16, 32}

// LinknameVectorLength is the single width sve_linkname is built for.
const LinknameVectorLength = 32

// RequiredVectorLength is the width sve_linkname requires; kept as the
// conservative answer for callers that do not distinguish the two flavours.
const RequiredVectorLength = LinknameVectorLength

// SupportsVectorLength reports whether vl is one of the supported widths.
func SupportsVectorLength(vl int, supported []int) bool {
	for _, v := range supported {
		if vl == v {
			return true
		}
	}
	return false
}

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
			return SupportsVectorLength(vl, WrapgocVectorLengths[:])
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
