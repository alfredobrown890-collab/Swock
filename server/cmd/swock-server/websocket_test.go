package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"testing"
)

func TestWebSocketUpgradeCarriesTunnelByteStream(t *testing.T) {
	serverSide, clientSide := net.Pipe()
	defer serverSide.Close()
	defer clientSide.Close()

	upgradedResult := make(chan net.Conn, 1)
	upgradeError := make(chan error, 1)
	go func() {
		upgraded, err := acceptWebSocket(serverSide)
		if err != nil {
			upgradeError <- err
			return
		}
		upgradedResult <- upgraded
	}()

	const key = "dGhlIHNhbXBsZSBub25jZQ=="
	_, err := io.WriteString(clientSide, "GET /tunnel HTTP/1.1\r\nHost: swock.test\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: "+key+"\r\nSec-WebSocket-Version: 13\r\n\r\n")
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(clientSide), nil)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("unexpected status: %s", response.Status)
	}
	acceptHash := sha1.Sum([]byte(key + webSocketGUID))
	if got, want := response.Header.Get("Sec-WebSocket-Accept"), base64.StdEncoding.EncodeToString(acceptHash[:]); got != want {
		t.Fatalf("unexpected accept hash: got %q, want %q", got, want)
	}

	var upgraded net.Conn
	select {
	case upgraded = <-upgradedResult:
	case err := <-upgradeError:
		t.Fatal(err)
	}

	clientWrite := make(chan error, 1)
	go func() {
		_, err := clientSide.Write([]byte{0x82, 0x82, 1, 2, 3, 4, 'S' ^ 1, 'W' ^ 2})
		clientWrite <- err
	}()
	message := make([]byte, 2)
	if _, err := io.ReadFull(upgraded, message); err != nil {
		t.Fatal(err)
	}
	if string(message) != "SW" {
		t.Fatalf("unexpected unmasked payload: %q", message)
	}
	if err := <-clientWrite; err != nil {
		t.Fatal(err)
	}

	serverWrite := make(chan error, 1)
	go func() {
		_, err := upgraded.Write([]byte("K1"))
		serverWrite <- err
	}()
	var frame [4]byte
	if _, err := io.ReadFull(clientSide, frame[:]); err != nil {
		t.Fatal(err)
	}
	if frame != [4]byte{0x82, 2, 'K', '1'} {
		t.Fatalf("unexpected server frame: %v", frame)
	}
	if err := <-serverWrite; err != nil {
		t.Fatal(err)
	}
}

func TestAcceptWebSocketPreservesRawTcp(t *testing.T) {
	serverSide, clientSide := net.Pipe()
	defer serverSide.Close()
	defer clientSide.Close()

	result := make(chan net.Conn, 1)
	go func() {
		conn, err := acceptWebSocket(serverSide)
		if err != nil {			t.Error(err)
			return
		}
		result <- conn
	}()

	writeResult := make(chan error, 1)
	go func() {
		_, err := clientSide.Write([]byte("SWK1"))
		writeResult <- err
	}()
	conn := <-result
	var header [4]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		t.Fatal(err)
	}
	if string(header[:]) != "SWK1" {
		t.Fatalf("unexpected raw data: %q", header)
	}
	if err := <-writeResult; err != nil {
		t.Fatal(err)
	}
}