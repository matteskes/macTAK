// commo_shim.h — commo's C++ API as plain C, for Swift (G3.1).
//
// commo's callbacks are abstract C++ classes (CoTMessageListener,
// ContactPresenceListener, InterfaceStatusListener, CommoLogger), which
// Swift cannot subclass. commo_shim.cpp implements them and forwards each
// callback to a C function pointer with the caller's context. The API is
// plain C, not C++, so Swift imports it without C++ interop, a compiler
// mode that can carry over to the modules importing one built with it.
//
// Threads: the callbacks run on commo's own threads, never the caller's.
// Every string passed to a callback is valid only during the call. No call
// throws: C++ exceptions stay inside the shim and come back as an error.

#ifndef MACTAK_COMMO_SHIM_H
#define MACTAK_COMMO_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mactak_commo mactak_commo;

// commo's CommoLogger levels, in its order.
enum {
    MACTAK_COMMO_LOG_VERBOSE = 0,
    MACTAK_COMMO_LOG_DEBUG,
    MACTAK_COMMO_LOG_WARNING,
    MACTAK_COMMO_LOG_INFO,
    MACTAK_COMMO_LOG_ERROR,
};

// commo's StreamingTransport values.
enum {
    MACTAK_COMMO_TCP = 0,
    MACTAK_COMMO_SSL = 1,
    MACTAK_COMMO_QUIC = 2,
};

// The kinds of CoT a mesh broadcast interface carries (commo's
// CoTMessageType): situational awareness, or chat.
enum {
    MACTAK_COMMO_SA = 0,
    MACTAK_COMMO_CHAT = 1,
};

typedef struct {
    void *context;
    void (*log)(void *context, int level, const char *message);
    /// One inbound CoT event; endpoint is the interface it came in on.
    void (*cot_received)(void *context, const char *xml, const char *endpoint);
    void (*contact_added)(void *context, const char *uid);
    void (*contact_removed)(void *context, const char *uid);
    /// endpoint is the interface's id, from mactak_commo_add_streaming or
    /// one of the mesh calls (mactak_commo_add_inbound and the rest). A
    /// mesh interface's statuses can arrive on the thread that added it,
    /// replayed when commo reported them before the add call returned.
    void (*interface_up)(void *context, const char *endpoint);
    void (*interface_down)(void *context, const char *endpoint);
    /// code is commo's NetInterfaceErrorCode.
    void (*interface_error)(void *context, const char *endpoint, int code);
    /// Progress of an enrollment (mactak_commo_enroll_init). step is commo's
    /// EnrollmentStep (0 keygen, 1 the CSR's config request, 2 signing),
    /// status its SimpleFileIOStatus (0 in progress, 1 success, more for
    /// failures). Only signing's success carries data: the new client
    /// identity as PKCS#12 under identity_password, and the CAs the server
    /// sent as PKCS#12 under trust_password (NULL when it sent none). The
    /// private key from keygen is never passed out on its own.
    void (*enrollment_update)(void *context, int enrollment, int step, int status, const char *info,
                              const uint8_t *identity, size_t identity_len,
                              const uint8_t *ca, size_t ca_len);
} mactak_commo_callbacks;

/// Initialize libxml2, OpenSSL and curl as commo expects (the work of the
/// Java binding's Commo.initThirdpartyNativeLibraries), and ignore SIGPIPE
/// for the whole process, as the JVM does: commo's socket writes don't
/// suppress it. Once per process; later calls return the first result.
/// 0 on success.
int mactak_commo_init_libraries(char *err, size_t errlen);

/// A new Commo identified as uid and callsign, delivering to callbacks
/// (copied). NULL on failure, with the reason in err.
mactak_commo *mactak_commo_create(const char *uid, const char *callsign,
                                  const mactak_commo_callbacks *callbacks,
                                  char *err, size_t errlen);

/// Connect to a TAK server's streaming port; commo reconnects on its own
/// until the interface is removed. TCP takes no certificates; SSL and QUIC
/// take the client identity and the CA as PKCS#12 bytes and their passwords.
/// Situational awareness and chat broadcasts go out on it. On success,
/// writes the interface's endpoint id to endpoint and returns 0.
int mactak_commo_add_streaming(mactak_commo *commo, int transport,
                               const char *host, int port,
                               const uint8_t *cert, size_t cert_len,
                               const uint8_t *ca, size_t ca_len,
                               const char *cert_password, const char *ca_password,
                               char *endpoint, size_t endpoint_len,
                               char *err, size_t errlen);

/// Disconnect and forget the interface with this endpoint id. 0 on success.
int mactak_commo_remove_streaming(mactak_commo *commo, const char *endpoint,
                                  char *err, size_t errlen);

/// Queue a CoT event for every connected interface. 0 when commo accepted
/// it (sending is asynchronous).
int mactak_commo_broadcast(mactak_commo *commo, const char *xml,
                           char *err, size_t errlen);

/// Queue a CoT event for the contacts with these uids. 0 when commo
/// accepted it.
int mactak_commo_send(mactak_commo *commo, const char *const *uids, size_t count,
                      const char *xml, char *err, size_t errlen);

// Mesh networking (G3.3): peers on the local network with no server, as
// ATAK's defaults have it (dev/g3/NOTES.md §G3.3): SA on multicast
// 239.2.3.1:6969, chat on 224.10.10.1:17012, direct TCP on port 4242.
// Interfaces are named as the system names them ("en0", "lo0"). Each call
// writes the new interface's id to endpoint, the id status callbacks carry,
// and returns 0; mactak_commo_remove_mesh takes the id back.

/// Multicast TTL (1-255), whether this host's own multicast comes back to
/// it (two clients on one Mac need it), and whether several sockets may
/// bind one port (ATAK turns it on). Set before adding mesh interfaces.
int mactak_commo_set_mesh_options(mactak_commo *commo, int ttl, int loopback,
                                  int address_reuse, char *err, size_t errlen);

/// Listen for CoT on UDP port on interface ifname, unicast and on each
/// multicast group (dotted decimal). Id "in:<ifname>:<port>".
int mactak_commo_add_inbound(mactak_commo *commo, const char *ifname, int port,
                             const char *const *groups, size_t group_count,
                             char *endpoint, size_t endpoint_len,
                             char *err, size_t errlen);

/// Send broadcasts of kind (MACTAK_COMMO_SA or MACTAK_COMMO_CHAT) out of
/// interface ifname to multicast group:port.
/// Id "out:<ifname>:<group>:<port>".
int mactak_commo_add_broadcast(mactak_commo *commo, const char *ifname, int kind,
                               const char *group, int port,
                               char *endpoint, size_t endpoint_len,
                               char *err, size_t errlen);

/// Accept CoT over TCP on port, on every interface: how a peer sends to
/// this client directly. Id "tcp:<port>".
int mactak_commo_add_tcp_inbound(mactak_commo *commo, int port,
                                 char *endpoint, size_t endpoint_len,
                                 char *err, size_t errlen);

/// Remove a mesh interface by its id. 0 on success.
int mactak_commo_remove_mesh(mactak_commo *commo, const char *endpoint,
                             char *err, size_t errlen);

/// Set up a certificate enrollment with a TAK server (commo's
/// enrollmentInit): keygen, then GET /Marti/api/tls/config and POST
/// /Marti/api/tls/signClient/v2 on host:port, with basic auth (or a bearer
/// token when use_token is nonzero). ca, the PKCS#12 truststore the server
/// must chain to, is required: commo with no CA accepts any server (#146).
/// verify_host also checks the server's name. On success writes the
/// enrollment's id, which enrollment_update carries; nothing happens until
/// mactak_commo_enroll_start. 0 on success.
int mactak_commo_enroll_init(mactak_commo *commo, const char *host, int port, int verify_host,
                             const char *user, const char *password, int use_token,
                             const uint8_t *ca, size_t ca_len, const char *ca_password,
                             const char *identity_password, const char *trust_password,
                             const char *key_password, int key_bits, const char *version,
                             int *enrollment, char *err, size_t errlen);

/// Start an enrollment set up by mactak_commo_enroll_init. 0 on success.
int mactak_commo_enroll_start(mactak_commo *commo, int enrollment, char *err, size_t errlen);

/// GET an https URL through the curl and OpenSSL 3 commo carries, the one
/// TLS stack (dev/g3/NOTES.md §G3.2). The server must chain to ca_pem (PEM
/// certificates, required: no system roots, no "accept anything");
/// verify_host also checks its name. Basic auth when user isn't NULL. https
/// only, no redirects, at most max_bytes of body, the whole request within
/// timeout_s. Needs mactak_commo_init_libraries first. On 0, *status is the
/// HTTP status and *body (free it with mactak_commo_free) holds *body_len
/// bytes; otherwise err says why, in curl's words.
int mactak_commo_https_get(const char *url, const char *user, const char *password,
                           const uint8_t *ca_pem, size_t ca_len, int verify_host,
                           size_t max_bytes, long timeout_s,
                           long *status, uint8_t **body, size_t *body_len,
                           char *err, size_t errlen);

/// Free memory the shim handed out (mactak_commo_https_get's body).
void mactak_commo_free(void *pointer);

/// Shut commo down and free it. No callback runs after this returns.
void mactak_commo_destroy(mactak_commo *commo);

#ifdef __cplusplus
}
#endif

#endif
