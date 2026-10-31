// Direct ABI/ownership comparison: local macOS 11 shim versus Apple's native
// SecTrustCopyCertificateChain on macOS 12+. Uses only offline DER fixtures.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static CFDataRef read_der(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long size = ftell(f);
    if (size <= 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    unsigned char *buf = malloc((size_t)size);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)size, f);
    fclose(f);
    CFDataRef data = got == (size_t)size ? CFDataCreate(kCFAllocatorDefault, buf, size) : NULL;
    free(buf);
    return data;
}

static int same_chain(CFArrayRef a, CFArrayRef b) {
    CFIndex count = CFArrayGetCount(a);
    if (count != CFArrayGetCount(b) || count < 1) return 0;
    for (CFIndex i = 0; i < count; i++) {
        SecCertificateRef ca = (SecCertificateRef)CFArrayGetValueAtIndex(a, i);
        SecCertificateRef cb = (SecCertificateRef)CFArrayGetValueAtIndex(b, i);
        if (!ca || !cb) return 0;
        CFDataRef da = SecCertificateCopyData(ca);
        CFDataRef db = SecCertificateCopyData(cb);
        int same = da && db && CFEqual(da, db);
        if (da) CFRelease(da);
        if (db) CFRelease(db);
        if (!same) return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: abi leaf.der intermediate.der root.der\n"); return 2; }
    CFMutableArrayRef input = CFArrayCreateMutable(kCFAllocatorDefault, 3, &kCFTypeArrayCallBacks);
    if (!input) return 1;
    for (int i = 1; i < 4; i++) {
        CFDataRef data = read_der(argv[i]);
        SecCertificateRef cert = data ? SecCertificateCreateWithData(kCFAllocatorDefault, data) : NULL;
        if (!data || !cert) { fprintf(stderr, "fixture parse failed\n"); return 1; }
        CFArrayAppendValue(input, cert);
        CFRelease(cert);
        CFRelease(data);
    }
    CFStringRef host = CFSTR("go.dev");
    SecPolicyRef policy = SecPolicyCreateSSL(true, host);
    SecTrustRef trust = NULL;
    if (!policy || SecTrustCreateWithCertificates(input, policy, &trust) != errSecSuccess || !trust) return 1;
    CFRelease(policy);
    CFRelease(input);
    struct tm when = {.tm_year = 126, .tm_mon = 9, .tm_mday = 31};
    CFDateRef date = CFDateCreate(kCFAllocatorDefault, (CFAbsoluteTime)(timegm(&when) - 978307200));
    if (!date || SecTrustSetVerifyDate(trust, date) != errSecSuccess) return 1;
    CFRelease(date);
    if (SecTrustSetNetworkFetchAllowed(trust, false) != errSecSuccess) return 1;
    CFErrorRef error = NULL;
    if (!SecTrustEvaluateWithError(trust, &error)) {
        fprintf(stderr, "trust evaluation failed before shim\n");
        if (error) CFShow(error);
        if (error) CFRelease(error);
        return 1;
    }
    if (error) CFRelease(error);
    if (SecTrustCopyCertificateChain(NULL) != NULL) { fprintf(stderr, "NULL trust accepted\n"); return 1; }
    CFArrayRef shim = SecTrustCopyCertificateChain(trust);
    if (!shim || CFArrayGetCount(shim) < 2) { fprintf(stderr, "shim chain missing\n"); return 1; }

    void *handle = dlopen("/System/Library/Frameworks/Security.framework/Versions/A/Security", RTLD_NOW | RTLD_FIRST);
    typedef CFArrayRef (*copy_chain_fn)(SecTrustRef);
    copy_chain_fn native = handle ? (copy_chain_fn)dlsym(handle, "SecTrustCopyCertificateChain") : NULL;
    if (native && native == &SecTrustCopyCertificateChain) {
        fprintf(stderr, "native lookup resolved to local shim\n"); return 1;
    }
    CFArrayRef original = native ? native(trust) : NULL;
    if (native && (!original || !same_chain(shim, original))) {
        fprintf(stderr, "shim/native chain mismatch\n"); return 1;
    }
    // certstore extracts a chain even if evaluation failed. Compare that
    // behavior too, using a parseable leaf with a corrupted signature.
    CFDataRef leaf_data = read_der(argv[1]);
    CFMutableDataRef corrupt = leaf_data ? CFDataCreateMutableCopy(kCFAllocatorDefault, 0, leaf_data) : NULL;
    if (leaf_data) CFRelease(leaf_data);
    if (!corrupt || CFDataGetLength(corrupt) < 1) return 1;
    CFIndex last = CFDataGetLength(corrupt) - 1;
    CFDataGetMutableBytePtr(corrupt)[last] ^= 1;
    SecCertificateRef bad_cert = SecCertificateCreateWithData(kCFAllocatorDefault, corrupt);
    CFRelease(corrupt);
    if (!bad_cert) return 1;
    SecPolicyRef bad_policy = SecPolicyCreateSSL(true, host);
    SecTrustRef bad_trust = NULL;
    if (!bad_policy || SecTrustCreateWithCertificates(bad_cert, bad_policy, &bad_trust) != errSecSuccess) return 1;
    CFRelease(bad_policy);
    CFRelease(bad_cert);
    CFErrorRef bad_error = NULL;
    if (SecTrustEvaluateWithError(bad_trust, &bad_error)) {
        fprintf(stderr, "corrupt leaf trusted\n"); return 1;
    }
    if (bad_error) CFRelease(bad_error);
    CFArrayRef bad_shim = SecTrustCopyCertificateChain(bad_trust);
    CFArrayRef bad_native = native ? native(bad_trust) : NULL;
    if (native && ((bad_shim == NULL) != (bad_native == NULL) ||
                   (bad_shim && !same_chain(bad_shim, bad_native)))) {
        fprintf(stderr, "failed-trust chain mismatch\n"); return 1;
    }
    printf("PASS failed-trust chain: shim count=%ld, native comparison=%s\n",
           bad_shim ? (long)CFArrayGetCount(bad_shim) : 0L,
           native ? "MATCH" : "UNAVAILABLE");
    if (bad_native) CFRelease(bad_native);
    if (bad_shim) CFRelease(bad_shim);
    CFRelease(bad_trust);
    CFRelease(trust);
    // The copied array must still own every certificate after trust releases.
    for (CFIndex i = 0; i < CFArrayGetCount(shim); i++) {
        SecCertificateRef cert = (SecCertificateRef)CFArrayGetValueAtIndex(shim, i);
        CFDataRef data = cert ? SecCertificateCopyData(cert) : NULL;
        if (!data || CFDataGetLength(data) == 0) {
            fprintf(stderr, "certificate lost after trust release\n"); return 1;
        }
        CFRelease(data);
    }
    printf("PASS ABI/ownership: chain count=%ld, native comparison=%s, NULL failure=PASS\n",
           (long)CFArrayGetCount(shim), native ? "MATCH" : "UNAVAILABLE");
    if (original) CFRelease(original);
    CFRelease(shim);
    if (handle) dlclose(handle);
    return 0;
}
