package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"runtime"
	"strconv"
)

// Linux auxv uses native-endian machine words; AT_CLKTCK is supplied by the
// kernel. No guessed HZ, libc/cgo or getconf/sysstat child process is needed.
func clockTicksFromAuxv(data []byte, width int, order binary.ByteOrder) (int64, error) {
	if (width != 4 && width != 8) || len(data)%(2*width) != 0 {
		return 0, fmt.Errorf("malformed auxiliary vector")
	}
	word := func(p []byte) uint64 {
		if width == 4 {
			return uint64(order.Uint32(p))
		}
		return order.Uint64(p)
	}
	for offset := 0; offset < len(data); offset += 2 * width {
		key, value := word(data[offset:]), word(data[offset+width:])
		if key == 0 {
			break
		}
		if key == 17 { // AT_CLKTCK, linux/include/uapi/linux/auxvec.h
			if value == 0 || value > uint64(^uint64(0)>>1) {
				return 0, fmt.Errorf("invalid AT_CLKTCK")
			}
			return int64(value), nil
		}
	}
	return 0, fmt.Errorf("AT_CLKTCK missing; refusing a hardcoded tick rate")
}
func kernelContext() (int64, int64, error) {
	if runtime.GOOS != "linux" {
		return 0, 0, fmt.Errorf("live /proc sampling requires Linux")
	}
	data, err := os.ReadFile("/proc/self/auxv")
	if err != nil {
		return 0, 0, err
	}
	ticks, err := clockTicksFromAuxv(data, strconv.IntSize/8, binary.NativeEndian)
	return ticks, int64(os.Getpagesize()), err
}
