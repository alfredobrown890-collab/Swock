package main

import (
	"bytes"
	"crypto/cipher"
	"crypto/rand"
	"net"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
)

func TestDirectionalSessionKeysAreIndependent(t *testing.T) {
	clientPrivate := make([]byte, privateSize)
	serverPrivate := make([]byte, privateSize)
	if _, err := rand.Read(clientPrivate); err != nil {
		t.Fatal(err)
	}
	if _, err := rand.Read(serverPrivate); err != nil {
		t.Fatal(err)
	}
	clientPublic, err := curve25519.X25519(clientPrivate, curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}
	serverPublic, err := curve25519.X25519(serverPrivate, curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}

	sessionSalt := bytes.Repeat([]byte{0x17}, 32)
	clientToServer, serverToClient, err := sessionKeys(serverPrivate, clientPublic, serverPublic, sessionSalt)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(clientToServer, serverToClient) {
		t.Fatal("directional keys must differ")
	}
	otherClientToServer, otherServerToClient, err := sessionKeys(serverPrivate, clientPublic, serverPublic, bytes.Repeat([]byte{0x29}, 32))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(clientToServer, otherClientToServer) || bytes.Equal(serverToClient, otherServerToClient) {
		t.Fatal("new session salt must produce new directional keys")
	}

	packet := []byte("test tunnel packet")
	clientCipher, err := chacha20poly1305.New(clientToServer)
	if err != nil {
		t.Fatal(err)
	}
	serverCipher, err := chacha20poly1305.New(clientToServer)
	if err != nil {
		t.Fatal(err)
	}
	wrongDirectionCipher, err := chacha20poly1305.New(serverToClient)
	if err != nil {
		t.Fatal(err)
	}
	frame := clientCipher.Seal(nil, nonce(0), packet, nil)
	opened, err := serverCipher.Open(nil, nonce(0), frame, nil)
	if err != nil || !bytes.Equal(opened, packet) {
		t.Fatalf("client-to-server decrypt failed: %v", err)
	}
	if _, err := wrongDirectionCipher.Open(nil, nonce(0), frame, nil); err == nil {
		t.Fatal("server-to-client key must not authenticate a client-to-server frame")
	}
}

func TestHandshakeProofRequiresMatchingDirectionalKey(t *testing.T) {
	clientKey := bytes.Repeat([]byte{0x11}, chacha20poly1305.KeySize)
	serverKey := bytes.Repeat([]byte{0x22}, chacha20poly1305.KeySize)
	clientAEAD, err := chacha20poly1305.New(clientKey)
	if err != nil {
		t.Fatal(err)
	}
	serverAEAD, err := chacha20poly1305.New(serverKey)
	if err != nil {
		t.Fatal(err)
	}
	var frame bytes.Buffer
	if err := writeHandshakeProof(&frame, clientAEAD, nonce(0), clientProof); err != nil {
		t.Fatal(err)
	}
	if err := readHandshakeProof(&frame, clientAEAD, nonce(0), clientProof); err != nil {
		t.Fatalf("valid client proof rejected: %v", err)
	}
	frame.Reset()
	if err := writeHandshakeProof(&frame, clientAEAD, nonce(0), clientProof); err != nil {
		t.Fatal(err)
	}
	if err := readHandshakeProof(&frame, serverAEAD, nonce(0), clientProof); err == nil {
		t.Fatal("proof authenticated under the wrong key")
	}
	var invalidProof cipher.AEAD = clientAEAD
	if err := readHandshakeProof(bytes.NewReader(nil), invalidProof, nonce(0), clientProof); err == nil {
		t.Fatal("empty proof frame was accepted")
	}
}

func TestIPv4PacketAddressExtraction(t *testing.T) {
	packet := make([]byte, 20)
	packet[0] = 0x45
	copy(packet[12:16], []byte{10, 8, 0, 7})
	copy(packet[16:20], []byte{1, 1, 1, 1})
	source, destination, ok := ipv4PacketAddresses(packet)
	if !ok || !source.Equal(net.IPv4(10, 8, 0, 7)) || !destination.Equal(net.IPv4(1, 1, 1, 1)) {
		t.Fatalf("unexpected packet addresses: source=%v destination=%v ok=%v", source, destination, ok)
	}
	if _, _, ok := ipv4PacketAddresses([]byte{0x60}); ok {
		t.Fatal("IPv6 packet must not be mapped to an IPv4 client")
	}
	if validTunnelIP(net.ParseIP("10.8.0.1")) || validTunnelIP(net.ParseIP("10.8.0.255")) || validTunnelIP(net.ParseIP("10.9.0.2")) {
		t.Fatal("address validator accepted an address outside the client pool")
	}
	if !validTunnelIP(net.ParseIP("10.8.0.254")) {
		t.Fatal("address validator rejected the last client address")
	}
}

func TestClientIPReadsMultipleAllowlistAssignments(t *testing.T) {
	path := filepath.Join(t.TempDir(), "allowed-keys")
	contents := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 10.8.0.2\n" +
		"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 10.8.0.3\n"
	if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
	server := &server{allowedFile: path}
	for key, expected := range map[string]net.IP{
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": net.IPv4(10, 8, 0, 2),
		"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": net.IPv4(10, 8, 0, 3),
	} {
		got, ok := server.clientIP(key)
		if !ok || !got.Equal(expected) {
			t.Fatalf("clientIP(%q) = %v, %v; want %v, true", key, got, ok, expected)
		}
	}
	if _, ok := server.clientIP("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"); ok {
		t.Fatal("unauthorized key was accepted")
	}
}

func TestClientIPRejectsInvalidPoolAndDuplicateAssignments(t *testing.T) {
	path := filepath.Join(t.TempDir(), "allowed-keys")
	contents := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 10.8.0.2\n" +
		"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 10.9.0.3\n" +
		"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc 10.8.0.2\n"
	if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
	server := &server{allowedFile: path}
	for _, key := range []string{
		"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
	} {
		if _, ok := server.clientIP(key); ok {
			t.Fatalf("accepted invalid/duplicate tunnel assignment for %s", key)
		}
	}
}

func TestServerRoutesReturnPacketsToDifferentClients(t *testing.T) {
	first := &client{tunnelIP: net.IPv4(10, 8, 0, 2)}
	second := &client{tunnelIP: net.IPv4(10, 8, 0, 3)}
	server := &server{clients: map[string]*client{
		first.tunnelIP.String():  first,
		second.tunnelIP.String(): second,
	}}
	for _, test := range []struct {
		destination net.IP
		want        *client
	}{
		{net.IPv4(10, 8, 0, 2), first},
		{net.IPv4(10, 8, 0, 3), second},
		{net.IPv4(10, 8, 0, 4), nil},
	} {
		packet := make([]byte, 20)
		packet[0] = 0x45
		copy(packet[16:20], test.destination.To4())
		if got := server.clientForPacket(packet); got != test.want {
			t.Fatalf("route for %s = %p, want %p", test.destination, got, test.want)
		}
	}
}
