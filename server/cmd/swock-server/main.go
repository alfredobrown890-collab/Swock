// Swock server terminates the protocol implemented by the Android client.
// It intentionally listens on a DNS-only hostname: Cloudflare's standard proxy
// cannot proxy arbitrary TCP VPN traffic.
package main

import (
	"bytes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
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
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
)

const (
	legacyMagic = "SWK1"
	magic       = "SWK2"
	maxFrame    = 65535 + chacha20poly1305.Overhead
	privateSize = 32
	tunSetIFF   = 0x400454ca
	iffTun      = 0x0001
	iffNoPI     = 0x1000
)

type keyList []string

func (keys *keyList) String() string { return fmt.Sprint([]string(*keys)) }
func (keys *keyList) Set(value string) error {
	if _, err := decodeKey(value); err != nil {
		return err
	}
	*keys = append(*keys, value)
	return nil
}

var (
	clientProof = []byte("SWK2 client key confirmation")
	serverProof = []byte("SWK2 server key confirmation")
)

type server struct {
	privateKey      []byte
	publicKey       []byte
	tun             *os.File
	allowed         map[string]net.IP
	allowedFile     string
	allowLegacySWK1 bool
	mu              sync.Mutex
	clients         map[string]*client
}

type client struct {
	conn     net.Conn
	tunnelIP net.IP
	txKey    []byte
	rxKey    []byte
	legacy   bool
	mu       sync.Mutex
	tx       uint64
	rx       uint64
}

func main() {
	listen := flag.String("listen", ":443", "comma-separated plain TCP/WebSocket listener addresses")
	tlsListen := flag.String("tls-listen", "", "comma-separated TLS/WSS listener addresses")
	tlsCertFile := flag.String("tls-cert", "", "TLS certificate PEM file (required with --tls-listen)")
	tlsKeyFile := flag.String("tls-key", "", "TLS private key PEM file")
	privateKeyHex := flag.String("private-key", "", "32-byte server X25519 private key, hexadecimal")
	privateKeyFile := flag.String("private-key-file", "", "path to a file containing the server private key")
	tunName := flag.String("tun-name", "swock0", "TUN interface name")
	allowLegacySWK1 := flag.Bool("allow-legacy-swk1", false, "allow legacy single-client SWK1 sessions (insecure nonce reuse; migration only)")
	var allowedClientKeys keyList
	flag.Var(&allowedClientKeys, "allowed-client-key", "allowed 32-byte client X25519 public key, hexadecimal (repeatable)")
	allowedClientKeyFile := flag.String("allowed-client-key-file", "", "path to a file containing one allowed client public key per line")
	flag.Parse()
	if *privateKeyFile != "" {
		contents, err := os.ReadFile(*privateKeyFile)
		if err != nil {
			log.Fatal(err)
		}
		*privateKeyHex = strings.TrimSpace(string(contents))
	}
	privateKey, err := decodeKey(*privateKeyHex)
	if err != nil {
		log.Fatal(err)
	}
	publicKey, err := curve25519.X25519(privateKey, curve25519.Basepoint)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("server public key: %x", publicKey)

	if len(allowedClientKeys) == 0 && *allowedClientKeyFile == "" {
		log.Fatal("at least one --allowed-client-key or --allowed-client-key-file is required")
	}
	tun, err := openTun(*tunName)
	if err != nil {
		log.Fatalf("open TUN: %v", err)
	}
	defer tun.Close()
	allowed := make(map[string]net.IP, len(allowedClientKeys))
	if len(allowedClientKeys) > 253 {
		log.Fatal("the 10.8.0.0/24 tunnel subnet supports at most 253 clients")
	}
	for index, key := range allowedClientKeys {
		allowed[key] = net.IPv4(10, 8, byte(index/253), byte(index%253+2)).To4()
	}

	s := &server{privateKey: privateKey, publicKey: publicKey, tun: tun, allowed: allowed, allowedFile: *allowedClientKeyFile, allowLegacySWK1: *allowLegacySWK1, clients: make(map[string]*client)}
	go s.readTun()
	if (*tlsCertFile == "") != (*tlsKeyFile == "") {
		log.Fatal("--tls-cert and --tls-key must be provided together")
	}
	if *tlsListen != "" && *tlsCertFile == "" {
		log.Fatal("--tls-cert and --tls-key are required with --tls-listen")
	}
	var tlsConfig *tls.Config
	if *tlsCertFile != "" {
		certificate, err := tls.LoadX509KeyPair(*tlsCertFile, *tlsKeyFile)
		if err != nil {
			log.Fatalf("load TLS certificate: %v", err)
		}
		tlsConfig = &tls.Config{
			Certificates: []tls.Certificate{certificate},
			MinVersion:   tls.VersionTLS12,
		}
	}
	plainAddresses := splitListeners(*listen)
	tlsAddresses := splitListeners(*tlsListen)
	if len(plainAddresses) == 0 && len(tlsAddresses) == 0 {
		log.Fatal("at least one listener is required")
	}
	for _, address := range plainAddresses {
		listener, err := net.Listen("tcp", address)
		if err != nil {
			log.Fatalf("listen %s: %v", address, err)
		}
		log.Printf("listening for TCP/WebSocket on %s", address)
		go s.serve(listener)
	}
	for _, address := range tlsAddresses {
		listener, err := net.Listen("tcp", address)
		if err != nil {
			log.Fatalf("listen %s: %v", address, err)
		}
		log.Printf("listening for TLS/WSS on %s", address)
		go s.serve(tls.NewListener(listener, tlsConfig))
	}
	select {}
}

func splitListeners(value string) []string {
	var listeners []string
	for _, address := range strings.Split(value, ",") {
		if address = strings.TrimSpace(address); address != "" {
			listeners = append(listeners, address)
		}
	}
	return listeners
}

func (s *server) serve(listener net.Listener) {
	defer listener.Close()
	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
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
	if _, err := io.ReadFull(conn, preface); err != nil {
		return
	}
	protocol := string(preface)
	if protocol != magic && protocol != legacyMagic {
		return
	}
	if protocol == legacyMagic && !s.allowLegacySWK1 {
		return
	}
	clientPublic := make([]byte, privateSize)
	if _, err := io.ReadFull(conn, clientPublic); err != nil {
		return
	}
	allowedIP, ok := s.clientIP(hex.EncodeToString(clientPublic))
	if !ok {
		return
	}
	legacy := protocol == legacyMagic
	if legacy {
		allowedIP = net.IPv4(10, 8, 0, 2).To4()
	}
	var clientToServerKey, serverToClientKey []byte
	var sessionSalt []byte
	if legacy {
		legacyKey := legacySessionKey(s.privateKey, clientPublic, s.publicKey)
		clientToServerKey, serverToClientKey = legacyKey, legacyKey
	} else {
		sessionSalt = make([]byte, 32)
		if _, err := rand.Read(sessionSalt); err != nil {
			return
		}
		clientToServerKey, serverToClientKey, err = sessionKeys(s.privateKey, clientPublic, s.publicKey, sessionSalt)
		if err != nil {
			return
		}
	}
	response := append([]byte(protocol), s.publicKey...)
	if !legacy {
		response = append(response, allowedIP...)
		response = append(response, sessionSalt...)
	}
	if _, err = conn.Write(response); err != nil {
		return
	}
	initialCounter := uint64(0)
	if !legacy {
		clientAEAD, err := chacha20poly1305.New(clientToServerKey)
		if err != nil {
			return
		}
		serverAEAD, err := chacha20poly1305.New(serverToClientKey)
		if err != nil {
			return
		}
		if err := readHandshakeProof(conn, clientAEAD, nonce(0), clientProof); err != nil {
			return
		}
		if err := writeHandshakeProof(conn, serverAEAD, nonce(0), serverProof); err != nil {
			return
		}
		initialCounter = 1
	}
	c := &client{conn: conn, tunnelIP: allowedIP, txKey: serverToClientKey, rxKey: clientToServerKey, legacy: legacy, tx: initialCounter, rx: initialCounter}
	clientRoute := allowedIP.String()
	s.mu.Lock()
	if existing := s.clients[clientRoute]; existing != nil {
		_ = existing.conn.Close()
	}
	s.clients[clientRoute] = c
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		if s.clients[clientRoute] == c {
			delete(s.clients, clientRoute)
		}
		s.mu.Unlock()
	}()
	log.Printf("client connected from %s on %s", conn.RemoteAddr(), clientRoute)
	aead, err := chacha20poly1305.New(c.rxKey)
	if err != nil {
		return
	}
	for {
		var length uint32
		if err := binary.Read(conn, binary.BigEndian, &length); err != nil || length < chacha20poly1305.Overhead || length > maxFrame {
			return
		}
		frame := make([]byte, length)
		if _, err := io.ReadFull(conn, frame); err != nil {
			return
		}
		packet, err := aead.Open(nil, nonce(c.rx), frame, nil)
		if err != nil {
			return
		}
		c.rx++
		sourceIP, _, ok := ipv4PacketAddresses(packet)
		if !ok || !sourceIP.Equal(c.tunnelIP) {
			return
		}
		if _, err := s.tun.Write(packet); err != nil {
			return
		}
	}
}

func readHandshakeProof(reader io.Reader, aead cipher.AEAD, proofNonce, expected []byte) error {
	var length uint32
	if err := binary.Read(reader, binary.BigEndian, &length); err != nil {
		return err
	}
	if length < uint32(aead.Overhead()) || length > uint32(aead.Overhead()+128) {
		return errors.New("invalid handshake proof length")
	}
	frame := make([]byte, length)
	if _, err := io.ReadFull(reader, frame); err != nil {
		return err
	}
	plaintext, err := aead.Open(nil, proofNonce, frame, nil)
	if err != nil {
		return err
	}
	if !bytes.Equal(plaintext, expected) {
		return errors.New("invalid handshake key confirmation")
	}
	return nil
}

func writeHandshakeProof(writer io.Writer, aead cipher.AEAD, proofNonce, proof []byte) error {
	frame := aead.Seal(nil, proofNonce, proof, nil)
	if err := binary.Write(writer, binary.BigEndian, uint32(len(frame))); err != nil {
		return err
	}
	_, err := writer.Write(frame)
	return err
}

func (s *server) clientIP(clientPublic string) (net.IP, bool) {
	if s.allowedFile == "" {
		ip, ok := s.allowed[clientPublic]
		return ip, ok
	}
	contents, err := os.ReadFile(s.allowedFile)
	if err != nil {
		log.Printf("read allowed client keys: %v", err)
		return nil, false
	}
	var clientAddress net.IP
	duplicateAddress := false
	addressOwners := make(map[string]string)
	for _, line := range strings.Split(string(contents), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		key := fields[0]
		var ip net.IP
		if len(fields) == 1 {
			ip = net.IPv4(10, 8, 0, 2).To4()
		} else if len(fields) == 2 {
			ip = net.ParseIP(fields[1]).To4()
			if !validTunnelIP(ip) {
				if key == clientPublic {
					return nil, false
				}
				continue
			}
		} else {
			if key == clientPublic {
				return nil, false
			}
			continue
		}
		address := ip.String()
		if owner, exists := addressOwners[address]; exists && owner != key {
			if owner == clientPublic || key == clientPublic {
				duplicateAddress = true
			}
		} else {
			addressOwners[address] = key
		}
		if key == clientPublic {
			clientAddress = ip
		}
	}
	return clientAddress, clientAddress != nil && !duplicateAddress
}

func validTunnelIP(ip net.IP) bool {
	address := ip.To4()
	return address != nil && address[0] == 10 && address[1] == 8 && address[2] == 0 && address[3] >= 2 && address[3] <= 254
}

func openTun(name string) (*os.File, error) {
	tun, err := os.OpenFile("/dev/net/tun", os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	ifr := make([]byte, 40)
	copy(ifr, []byte(name))
	*(*uint16)(unsafe.Pointer(&ifr[16])) = iffTun | iffNoPI
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, tun.Fd(), tunSetIFF, uintptr(unsafe.Pointer(&ifr[0])))
	if errno != 0 {
		_ = tun.Close()
		return nil, errno
	}
	return tun, nil
}

func (s *server) readTun() {
	packet := make([]byte, 65535)
	for {
		n, err := s.tun.Read(packet)
		if err != nil {
			log.Printf("TUN read stopped: %v", err)
			return
		}
		c := s.clientForPacket(packet[:n])
		if c != nil {
			_ = c.send(packet[:n])
		}
	}
}

func (s *server) clientForPacket(packet []byte) *client {
	_, destinationIP, ok := ipv4PacketAddresses(packet)
	if !ok {
		return nil
	}
	s.mu.Lock()
	c := s.clients[destinationIP.String()]
	s.mu.Unlock()
	return c
}

func decodeKey(value string) ([]byte, error) {
	key, err := hex.DecodeString(value)
	if err != nil || len(key) != privateSize {
		return nil, errors.New("--private-key must be exactly 32 bytes of hexadecimal")
	}
	return key, nil
}

func nonce(counter uint64) []byte {
	n := make([]byte, chacha20poly1305.NonceSize)
	binary.BigEndian.PutUint64(n[4:], counter)
	return n
}

func legacySessionKey(privateKey, clientPublic, serverPublic []byte) []byte {
	shared, err := curve25519.X25519(privateKey, clientPublic)
	if err != nil {
		return nil
	}
	hash := sha256.Sum256(append(append(shared, clientPublic...), serverPublic...))
	return hash[:]
}

func sessionKeys(privateKey, clientPublic, serverPublic, sessionSalt []byte) ([]byte, []byte, error) {
	shared, err := curve25519.X25519(privateKey, clientPublic)
	if err != nil {
		return nil, nil, err
	}
	if len(sessionSalt) != 32 {
		return nil, nil, errors.New("SWK2 session salt must be 32 bytes")
	}
	transcriptInput := make([]byte, 0, len(shared)+len(clientPublic)+len(serverPublic)+len(sessionSalt))
	transcriptInput = append(transcriptInput, shared...)
	transcriptInput = append(transcriptInput, clientPublic...)
	transcriptInput = append(transcriptInput, serverPublic...)
	transcriptInput = append(transcriptInput, sessionSalt...)
	transcript := sha256.Sum256(transcriptInput)
	clientToServer := sha256.Sum256(append(transcript[:], []byte("swock-v2-client-to-server")...))
	serverToClient := sha256.Sum256(append(transcript[:], []byte("swock-v2-server-to-client")...))
	return clientToServer[:], serverToClient[:], nil
}

func ipv4PacketAddresses(packet []byte) (net.IP, net.IP, bool) {
	if len(packet) < 20 || packet[0]>>4 != 4 {
		return nil, nil, false
	}
	headerLength := int(packet[0]&0x0f) * 4
	if headerLength < 20 || len(packet) < headerLength {
		return nil, nil, false
	}
	return net.IP(packet[12:16]), net.IP(packet[16:20]), true
}

func (c *client) send(packet []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	aead, err := chacha20poly1305.New(c.txKey)
	if err != nil {
		return err
	}
	frame := aead.Seal(nil, nonce(c.tx), packet, nil)
	c.tx++
	if err := binary.Write(c.conn, binary.BigEndian, uint32(len(frame))); err != nil {
		return err
	}
	_, err = c.conn.Write(frame)
	return err
}

func randomKey() string {
	key := make([]byte, privateSize)
	if _, err := rand.Read(key); err != nil {
		panic(err)
	}
	return hex.EncodeToString(key)
}

var _ = randomKey
