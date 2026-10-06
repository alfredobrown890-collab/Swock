package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log"

	"golang.org/x/crypto/curve25519"
)

func main() {
	privateKey := make([]byte, 32)
	if _, err := rand.Read(privateKey); err != nil {
		log.Fatal(err)
	}
	publicKey, err := curve25519.X25519(privateKey, curve25519.Basepoint)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("private=%s\npublic=%s\n", hex.EncodeToString(privateKey), hex.EncodeToString(publicKey))
}
