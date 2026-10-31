// Offline certificate-verification probes for the macOS 11 chain shim.
// Build with Roots=nil and no fallback roots: this selects Go's Darwin
// Security.framework verifier. See run.sh for shim/native builds.
package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"time"
)

var at = time.Date(2026, 10, 31, 0, 0, 0, 0, time.UTC)

func check(name string, wantOK bool, cert *x509.Certificate, opts x509.VerifyOptions) error {
	if opts.Roots != nil {
		return fmt.Errorf("%s: Roots must be nil to select the system verifier", name)
	}
	chains, err := cert.Verify(opts)
	ok := err == nil
	if ok != wantOK {
		return fmt.Errorf("%s: got ok=%v chains=%d err=%v; want ok=%v", name, ok, len(chains), err, wantOK)
	}
	if ok {
		if len(chains) == 0 || len(chains[0]) < 2 || !bytes.Equal(chains[0][0].Raw, cert.Raw) {
			return fmt.Errorf("%s: verifier returned an incomplete or wrong chain", name)
		}
	}
	fmt.Printf("PASS %-22s accepted=%v chains=%d err=%v\n", name, ok, len(chains), err)
	return nil
}

func localUntrusted() (*x509.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "local.invalid"},
		DNSNames: []string{"local.invalid"}, NotBefore: at.Add(-time.Hour),
		NotAfter: at.Add(time.Hour), ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		KeyUsage: x509.KeyUsageDigitalSignature,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	return x509.ParseCertificate(der)
}

func run(path string) error {
	pemBytes, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var certs []*x509.Certificate
	for len(pemBytes) > 0 {
		block, rest := pem.Decode(pemBytes)
		if block == nil {
			return errors.New("invalid fixture PEM")
		}
		pemBytes = bytes.TrimSpace(rest)
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return err
		}
		certs = append(certs, cert)
	}
	if len(certs) < 2 {
		return errors.New("fixture must contain a leaf and intermediate")
	}
	leaf := certs[0]
	intermediates := x509.NewCertPool()
	for _, cert := range certs[1:] {
		intermediates.AddCert(cert)
	}
	base := x509.VerifyOptions{DNSName: "go.dev", CurrentTime: at, Intermediates: intermediates}
	if err := check("valid trusted chain", true, leaf, base); err != nil {
		return err
	}

	self, err := localUntrusted()
	if err != nil {
		return err
	}
	if err := check("untrusted self-signed", false, self, x509.VerifyOptions{DNSName: "local.invalid", CurrentTime: at}); err != nil {
		return err
	}
	for _, tc := range []struct {
		name string
		opts x509.VerifyOptions
	}{
		{"expired", x509.VerifyOptions{DNSName: "go.dev", CurrentTime: leaf.NotAfter.Add(24 * time.Hour), Intermediates: intermediates}},
		{"not yet valid", x509.VerifyOptions{DNSName: "go.dev", CurrentTime: leaf.NotBefore.Add(-24 * time.Hour), Intermediates: intermediates}},
		{"hostname mismatch", x509.VerifyOptions{DNSName: "wrong.invalid", CurrentTime: at, Intermediates: intermediates}},
		{"incorrect usage", x509.VerifyOptions{DNSName: "go.dev", CurrentTime: at, Intermediates: intermediates, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}},
	} {
		if err := check(tc.name, false, leaf, tc.opts); err != nil {
			return err
		}
	}
	// A bad signature is parseable but must fail platform trust evaluation.
	badDER := bytes.Clone(leaf.Raw)
	badDER[len(badDER)-1] ^= 1
	bad, err := x509.ParseCertificate(badDER)
	if err == nil {
		if err := check("invalid signature", false, bad, base); err != nil {
			return err
		}
	} else {
		fmt.Printf("PASS invalid signature        rejected during parsing: %v\n", err)
	}
	if _, err := x509.ParseCertificate([]byte{0x30, 0x01, 0xff}); err == nil {
		return errors.New("malformed DER accepted")
	}
	fmt.Println("PASS malformed DER          rejected during parsing")
	// Missing intermediate is host-cache dependent, so report it as a probe,
	// not a fixed pass/fail assertion.
	_, err = leaf.Verify(x509.VerifyOptions{DNSName: "go.dev", CurrentTime: at})
	fmt.Printf("INFO missing intermediate    accepted=%v err=%v (AIA/cache dependent)\n", err == nil, err)
	return nil
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: certchain-security <chain.pem>")
		os.Exit(2)
	}
	if err := run(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, "FAIL", err)
		os.Exit(1)
	}
}
