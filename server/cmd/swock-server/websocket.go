package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
)

const webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConn) Read(buffer []byte) (int, error) { return c.reader.Read(buffer) }

type webSocketConn struct {
	net.Conn
	reader   *bufio.Reader
	payload  []byte
	fragment []byte
	writeMu  sync.Mutex
}

func acceptWebSocket(conn net.Conn) (net.Conn, error) {
	reader := bufio.NewReader(conn)
	prefix, err := reader.Peek(4)
	if err != nil {		return nil, err
	}
	if string(prefix) != "GET " {
		return &bufferedConn{Conn: conn, reader: reader}, nil
	}
	request, err := http.ReadRequest(reader)
	if err != nil {
		return nil, err
	}
	defer request.Body.Close()
	if request.Method != http.MethodGet ||
		!headerContainsToken(request.Header, "Connection", "upgrade") ||
		!strings.EqualFold(request.Header.Get("Upgrade"), "websocket") ||
		request.Header.Get("Sec-WebSocket-Version") != "13" {
		return nil, errors.New("invalid WebSocket upgrade request")
	}
	key := request.Header.Get("Sec-WebSocket-Key")
	decodedKey, err := base64.StdEncoding.DecodeString(key)
	if err != nil || len(decodedKey) != 16 {
		return nil, errors.New("invalid WebSocket key")
	}
	acceptHash := sha1.Sum([]byte(key + webSocketGUID))
	response := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + base64.StdEncoding.EncodeToString(acceptHash[:]) + "\r\n\r\n"
	if _, err := io.WriteString(conn, response); err != nil {
		return nil, err
	}
	return &webSocketConn{Conn: conn, reader: reader}, nil
}

func headerContainsToken(header http.Header, name, expected string) bool {
	for _, value := range header.Values(name) {
		for _, token := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(token), expected) {
				return true
			}
		}
	}
	return false
}

func (c *webSocketConn) Read(buffer []byte) (int, error) {
	if len(buffer) == 0 {
		return 0, nil
	}
	for len(c.payload) == 0 {
		if err := c.readFrame(); err != nil {			return 0, err
		}
	}
	n := copy(buffer, c.payload)
	c.payload = c.payload[n:]
	return n, nil
}

func (c *webSocketConn) readFrame() error {
	for {
		var header [2]byte
		if _, err := io.ReadFull(c.reader, header[:]); err != nil {			return err
		}
		if header[0]&0x70 != 0 {			return errors.New("unsupported WebSocket extensions")
		}
		final := header[0]&0x80 != 0
		opcode := header[0] & 0x0f
		masked := header[1]&0x80 != 0
		if !masked {
			return errors.New("client WebSocket frame is not masked")
		}
		length := uint64(header[1] & 0x7f)
		switch length {
		case 126:
			var extended [2]byte
			if _, err := io.ReadFull(c.reader, extended[:]); err != nil {				return err
			}
			length = uint64(binary.BigEndian.Uint16(extended[:]))
		case 127:
			var extended [8]byte
			if _, err := io.ReadFull(c.reader, extended[:]); err != nil {				return err
			}
			length = binary.BigEndian.Uint64(extended[:])
		}
		if length > 1<<20 {			return errors.New("WebSocket frame exceeds the allowed size")
		}
		if opcode >= 0x8 && (!final || length > 125) {
			return errors.New("invalid WebSocket control frame")
		}
		var mask [4]byte
		if _, err := io.ReadFull(c.reader, mask[:]); err != nil {			return err
		}
		frame := make([]byte, int(length))
		if _, err := io.ReadFull(c.reader, frame); err != nil {			return err
		}
		for index := range frame {
			frame[index] ^= mask[index%4]
		}
		switch opcode {
		case 0x0:
			if len(c.fragment) == 0 {
				return errors.New("unexpected WebSocket continuation frame")
			}
			c.fragment = append(c.fragment, frame...)
			if final {
				c.payload, c.fragment = c.fragment, nil
				return nil
			}
		case 0x2:
			if len(c.fragment) != 0 {
				return errors.New("interleaved fragmented WebSocket message")
			}
			if final {
				c.payload = frame
				return nil
			}
			c.fragment = frame
		case 0x8:
			_ = c.writeFrame(0x8, frame)
			return io.EOF
		case 0x9:
			if err := c.writeFrame(0xA, frame); err != nil {				return err
			}
		case 0xA:
		default:
			return fmt.Errorf("unsupported WebSocket opcode: %d", opcode)
		}
	}
}

func (c *webSocketConn) Write(payload []byte) (int, error) {
	if err := c.writeFrame(0x2, payload); err != nil {		return 0, err
	}
	return len(payload), nil
}

func (c *webSocketConn) writeFrame(opcode byte, payload []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	header := make([]byte, 0, 10+len(payload))
	header = append(header, 0x80|opcode)
	switch {
	case len(payload) < 126:
		header = append(header, byte(len(payload)))
	case len(payload) <= 0xffff:
		header = append(header, 126, byte(len(payload)>>8), byte(len(payload)))
	default:
		header = append(header, 127)
		var extended [8]byte
		binary.BigEndian.PutUint64(extended[:], uint64(len(payload)))
		header = append(header, extended[:]...)
	}
	if err := writeAll(c.Conn, header); err != nil {
		return err
	}
	return writeAll(c.Conn, payload)
}

func writeAll(writer io.Writer, value []byte) error {
	for len(value) > 0 {
		count, err := writer.Write(value)
		if err != nil {
			return err
		}
		if count == 0 {
			return io.ErrShortWrite
		}
		value = value[count:]
	}
	return nil
}