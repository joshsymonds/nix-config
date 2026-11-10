// Copyright (c) Tailscale Inc & AUTHORS
// SPDX-License-Identifier: BSD-3-Clause

// This test is run by multitun-test.sh against a copy of libtailscale's
// multitun.go in its own package, because libtailscale only compiles for
// Android.

package libtailscale

import (
	"errors"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/tailscale/wireguard-go/tun"
)

// defaultMTU is defined in libtailscale/tailscale.go, which is not copied
// into the test package.
const defaultMTU = 1280

var errFakeClosed = errors.New("fake tun closed")

// fakeTUN is a tun.Device whose reads block until it is closed.
type fakeTUN struct {
	closeOnce sync.Once
	closed    chan struct{}
	events    chan tun.Event
}

var _ tun.Device = (*fakeTUN)(nil)

func newFakeTUN() *fakeTUN {
	return &fakeTUN{closed: make(chan struct{}), events: make(chan tun.Event)}
}

func (f *fakeTUN) File() *os.File { return nil }

func (f *fakeTUN) Read(slab []byte, packets []tun.ReadPacket) (int, error) {
	<-f.closed
	return 0, errFakeClosed
}

func (f *fakeTUN) Write(bufs [][]byte, offset int) (int, error) {
	return len(bufs), nil
}

func (f *fakeTUN) MTU() (int, error) { return defaultMTU, nil }

func (f *fakeTUN) Name() (string, error) { return "fake", nil }

func (f *fakeTUN) Events() <-chan tun.Event { return f.events }

func (f *fakeTUN) Close() error {
	f.closeOnce.Do(func() { close(f.closed) })
	return nil
}

func (f *fakeTUN) BatchSize() int { return 1 }

// within runs fn and fails the test if it does not return in time.
func within(t *testing.T, d time.Duration, fn func()) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		fn()
	}()
	select {
	case <-done:
	case <-time.After(d):
		t.Fatalf("did not return within %v", d)
	}
}

// TestMultiTUNTwoDevicesShutdown adds a second device, which supersedes the
// first, then shuts down. The unpatched multiTUN closes the first device's
// close channel twice and panics with "close of closed channel".
func TestMultiTUNTwoDevicesShutdown(t *testing.T) {
	within(t, 10*time.Second, func() {
		m := newTUNDevices()
		m.add(newFakeTUN())
		m.add(newFakeTUN())
		m.Shutdown()
	})
}

// TestMultiTUNBurstShutdown adds three devices back to back, then shuts down.
func TestMultiTUNBurstShutdown(t *testing.T) {
	within(t, 10*time.Second, func() {
		m := newTUNDevices()
		for range 3 {
			m.add(newFakeTUN())
		}
		m.Shutdown()
	})
}
