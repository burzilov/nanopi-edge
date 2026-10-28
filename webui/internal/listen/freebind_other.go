//go:build !linux

package listen

import "syscall"

func freebindControl(network, address string, c syscall.RawConn) error { return nil }
