// Swock server terminates the protocol implemented by the Android client.
// It intentionally listens on a DNS-only hostname: Cloudflare's standard proxy
// cannot proxy arbitrary TCP VPN traffic.
package main

import (
	"crypto/tls"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"syscall"
	"sync"
	"unsafe"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
)

const (
	magic       = "SWK1"
	maxFrame    = 65535 + chacha20poly1305.Overhead
	privateSize = 32
	tunSetIFF   = 0x400454ca
	iffTun      = 0x0001
	iffNoPI     = 0x1000
)

type keyList []string

func (keys *keyList) String() string { return fmt.Sprint([]string(*keys)) }
func (keys *keyList) Set(value string) error {
	if _, err := decodeKey(value); err != nil { return err }
	*keys = append(*keys, value)
	return nil
}

type server struct {
	privateKey []byte
	publicKey  []byte
	tun        *os.File
	allowed    map[string]bool
	allowedFile string
	mu         sync.Mutex
	client     *client
}

type client struct {
	conn net.Conn
	key  []byte
	mu   sync.Mutex
	tx   uint64
	rx   uint64
}

func main() {
	listen := flag.String("listen", ":443", "comma-separated plain TCP/WebSocket listener addresses")
	tlsListen := flag.String("tls-listen", "", "comma-separated TLS/WSS listener addresses")
	tlsCertFile := flag.String("tls-cert", "", "TLS certificate PEM file (required with --tls-listen)")
	tlsKeyFile := flag.String("tls-key", "", "TLS private key PEM file")
	privateKeyHex := flag.String("private-key", "", "32-byte server X25519 private key, hexadecimal")
	privateKeyFile := flag.String("private-key-file", "", "path to a file containing the server private key")
	tunName := flag.String("tun-name", "swock0", "TUN interface name")
	var allowedClientKeys keyList
	flag.Var(&allowedClientKeys, "allowed-client-key", "allowed 32-byte client X25519 public key, hexadecimal (repeatable)")
	allowedClientKeyFile := flag.String("allowed-client-key-file", "", "path to a file containing one allowed client public key per line")
	flag.Parse()
	if *privateKeyFile != "" {
		contents, err := os.ReadFile(*privateKeyFile)
		if err != nil { log.Fatal(err) }
		*privateKeyHex = strings.TrimSpace(string(contents))
	}
	if *allowedClientKeyFile != "" {
		contents, err := os.ReadFile(*allowedClientKeyFile)
		if err != nil { log.Fatal(err) }
		for _, value := range strings.Fields(string(contents)) {
			if err := allowedClientKeys.Set(value); err != nil { log.Fatal(err) }
		}
	}

	privateKey, err := decodeKey(*privateKeyHex)
	if err != nil { log.Fatal(err) }
	publicKey, err := curve25519.X25519(privateKey, curve25519.Basepoint)
	if err != nil { log.Fatal(err) }
	log.Printf("server public key: %x", publicKey)

	if len(allowedClientKeys) == 0 && *allowedClientKeyFile == "" { log.Fatal("at least one --allowed-client-key or --allowed-client-key-file is required") }
	tun, err := openTun(*tunName)
	if err != nil { log.Fatalf("open TUN: %v", err) }
	defer tun.Close()
	allowed := make(map[string]bool, len(allowedClientKeys))
	for _, key := range allowedClientKeys { allowed[key] = true }

	s := &server{privateKey: privateKey, publicKey: publicKey, tun: tun, allowed: allowed, allowedFile: *allowedClientKeyFile}
	go s.readTun()
	if (*tlsCertFile == "") != (*tlsKeyFile == "") {
		log.Fatal("--tls-cert and --tls-key must be provided together")
	}
	if *tlsListen != "" && *tlsCertFile == "" { log.Fatal("--tls-cert and --tls-key are required with --tls-listen") }
	var tlsConfig *tls.Config
	if *tlsCertFile != "" {
		certificate, err := tls.LoadX509KeyPair(*tlsCertFile, *tlsKeyFile)
		if err != nil { log.Fatalf("load TLS certificate: %v", err) }
		tlsConfig = &tls.Config{
			Certificates: []tls.Certificate{certificate},
			MinVersion: tls.VersionTLS12,
		}
	}
	plainAddresses := splitListeners(*listen)
	tlsAddresses := splitListeners(*tlsListen)
	if len(plainAddresses) == 0 && len(tlsAddresses) == 0 { log.Fatal("at least one listener is required") }
	for _, address := range plainAddresses {
		listener, err := net.Listen("tcp", address)
		if err != nil { log.Fatalf("listen %s: %v", address, err) }
		log.Printf("listening for TCP/WebSocket on %s", address)
		go s.serve(listener)
	}
	for _, address := range tlsAddresses {
		listener, err := net.Listen("tcp", address)
		if err != nil { log.Fatalf("listen %s: %v", address, err) }
		log.Printf("listening for TLS/WSS on %s", address)
		go s.serve(tls.NewListener(listener, tlsConfig))
	}
	select {}
}

func splitListeners(value string) []string {
	var listeners []string
	for _, address := range strings.Split(value, ",") {
		if address = strings.TrimSpace(address); address != "" { listeners = append(listeners, address) }
	}
	return listeners
}

func (s *server) serve(listener net.Listener) {
	defer listener.Close()
	for {
		conn, err := listener.Accept()
		if err != nil { log.Printf("accept: %v", err); continue }
		go s.handle(conn)
	}
}

func (s *server) handle(conn net.Conn) {
	defer conn.Close()
	transportConn, err := acceptWebSocket(conn)
	if err != nil {
		log.Printf("transport handshake from %s: %v", conn.RemoteAddr(), err)
		return
	}
	conn = transportConn
	preface := make([]byte, len(magic))
	if _, err := io.ReadFull(conn, preface); err != nil || string(preface) != magic { return }
	clientPublic := make([]byte, privateSize)
	if _, err := io.ReadFull(conn, clientPublic); err != nil { return }
	if !s.isAllowed(hex.EncodeToString(clientPublic)) { return }
	key, err := sessionKey(s.privateKey, clientPublic, s.publicKey)
	if err != nil { return }
	if _, err = conn.Write(append([]byte(magic), s.publicKey...)); err != nil { return }
	c := &client{conn: conn, key: key}
	s.mu.Lock()
	if s.client != nil { _ = s.client.conn.Close() }
	s.client = c
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		if s.client == c { s.client = nil }
		s.mu.Unlock()
	}()
	log.Printf("client connected from %s", conn.RemoteAddr())
	aead, err := chacha20poly1305.New(key)
	if err != nil { return }
	for {
		var length uint32
		if err := binary.Read(conn, binary.BigEndian, &length); err != nil || length < chacha20poly1305.Overhead || length > maxFrame { return }
		frame := make([]byte, length)
		if _, err := io.ReadFull(conn, frame); err != nil { return }
		packet, err := aead.Open(nil, nonce(c.rx), frame, nil)
		if err != nil { return }
		c.rx++
		if _, err := s.tun.Write(packet); err != nil { return }
	}
}

func (s *server) isAllowed(clientPublic string) bool {
	if s.allowedFile == "" {
		return s.allowed[clientPublic]
	}
	contents, err := os.ReadFile(s.allowedFile)
	if err != nil {
		log.Printf("read allowed client keys: %v", err)
		return false
	}
	for _, value := range strings.Fields(string(contents)) {
		if value == clientPublic {
			return true
		}
	}
	return false
}

func openTun(name string) (*os.File, error) {
	tun, err := os.OpenFile("/dev/net/tun", os.O_RDWR, 0)
	if err != nil { return nil, err }
	ifr := make([]byte, 40)
	copy(ifr, []byte(name))
	*(*uint16)(unsafe.Pointer(&ifr[16])) = iffTun | iffNoPI
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, tun.Fd(), tunSetIFF, uintptr(unsafe.Pointer(&ifr[0])))
	if errno != 0 { _ = tun.Close(); return nil, errno }
	return tun, nil
}

func (s *server) readTun() {
	packet := make([]byte, 65535)
	for {
		n, err := s.tun.Read(packet)
		if err != nil { log.Printf("TUN read stopped: %v", err); return }
		s.mu.Lock()
		c := s.client
		s.mu.Unlock()
		if c != nil { _ = c.send(packet[:n]) }
	}
}

func decodeKey(value string) ([]byte, error) {
	key, err := hex.DecodeString(value)
	if err != nil || len(key) != privateSize { return nil, errors.New("--private-key must be exactly 32 bytes of hexadecimal") }
	return key, nil
}

func nonce(counter uint64) []byte {
	n := make([]byte, chacha20poly1305.NonceSize)
	binary.BigEndian.PutUint64(n[4:], counter)
	return n
}

func sessionKey(privateKey, clientPublic, serverPublic []byte) ([]byte, error) {
	shared, err := curve25519.X25519(privateKey, clientPublic)
	if err != nil { return nil, err }
	hash := sha256.Sum256(append(append(shared, clientPublic...), serverPublic...))
	return hash[:], nil
}

func (c *client) send(packet []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	aead, err := chacha20poly1305.New(c.key)
	if err != nil { return err }
	frame := aead.Seal(nil, nonce(c.tx), packet, nil)
	c.tx++
	if err := binary.Write(c.conn, binary.BigEndian, uint32(len(frame))); err != nil { return err }
	_, err = c.conn.Write(frame)
	return err
}

func randomKey() string {
	key := make([]byte, privateSize)
	if _, err := rand.Read(key); err != nil { panic(err) }
	return hex.EncodeToString(key)
}

var _ = randomKey
