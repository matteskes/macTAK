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
};

typedef struct {
    void *context;
    void (*log)(void *context, int level, const char *message);
    /// One inbound CoT event; endpoint is the interface it came in on.
    void (*cot_received)(void *context, const char *xml, const char *endpoint);
    void (*contact_added)(void *context, const char *uid);
    void (*contact_removed)(void *context, const char *uid);
    /// endpoint is a streaming interface's id (mactak_commo_add_streaming),
    /// or "" for other kinds of interface.
    void (*interface_up)(void *context, const char *endpoint);
    void (*interface_down)(void *context, const char *endpoint);
    /// code is commo's NetInterfaceErrorCode.
    void (*interface_error)(void *context, const char *endpoint, int code);
} mactak_commo_callbacks;

/// Initialize libxml2, OpenSSL and curl as commo expects (the work of the
/// Java binding's Commo.initThirdpartyNativeLibraries). Once per process;
/// later calls return the first result. 0 on success.
int mactak_commo_init_libraries(char *err, size_t errlen);

/// A new Commo identified as uid and callsign, delivering to callbacks
/// (copied). NULL on failure, with the reason in err.
mactak_commo *mactak_commo_create(const char *uid, const char *callsign,
                                  const mactak_commo_callbacks *callbacks,
                                  char *err, size_t errlen);

/// Connect to a TAK server's streaming port; commo reconnects on its own
/// until the interface is removed. TCP takes no certificates; SSL takes the
/// client identity and the CA as PKCS#12 bytes and their passwords.
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

/// Shut commo down and free it. No callback runs after this returns.
void mactak_commo_destroy(mactak_commo *commo);

#ifdef __cplusplus
}
#endif

#endif
