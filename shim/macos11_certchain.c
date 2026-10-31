// Compatibility implementation for the macOS 12 SecTrustCopyCertificateChain
// API used by Go 1.27 crypto/x509 and tailscale/certstore. The older APIs
// return the same evaluated chain and are available on macOS 11.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

CFArrayRef SecTrustCopyCertificateChain(SecTrustRef trust) {
    if (trust == NULL) return NULL;
    CFIndex count = SecTrustGetCertificateCount(trust);
    if (count <= 0) return NULL;
    CFMutableArrayRef chain = CFArrayCreateMutable(kCFAllocatorDefault, count,
                                                  &kCFTypeArrayCallBacks);
    if (chain == NULL) return NULL;
    for (CFIndex i = 0; i < count; i++) {
        SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, i);
        if (cert == NULL) {
            CFRelease(chain);
            return NULL;
        }
        // CFArray retains the certificate before the borrowed reference expires.
        CFArrayAppendValue(chain, cert);
    }
    return chain;
}
