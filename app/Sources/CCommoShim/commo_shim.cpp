// commo_shim.cpp — commo's listeners forwarded to C callbacks (commo_shim.h).

#include "commo_shim.h"

#include <commo.h>

#include <dlfcn.h>

#include <cstdio>
#include <cstring>
#include <exception>
#include <map>
#include <mutex>
#include <string>
#include <vector>

using namespace atakmap::commoncommo;

namespace {

void setError(char *err, size_t errlen, const std::string &message) {
    if (err && errlen > 0)
        std::snprintf(err, errlen, "%s", message.c_str());
}

const char *resultName(CommoResult r) {
    switch (r) {
        case COMMO_SUCCESS: return "success";
        case COMMO_ILLEGAL_ARGUMENT: return "illegal argument";
        case COMMO_CONTACT_GONE: return "contact gone";
        case COMMO_INVALID_CERT: return "invalid client certificate";
        case COMMO_INVALID_CACERT: return "invalid CA certificate";
        case COMMO_INVALID_CERT_PASSWORD: return "wrong client certificate password";
        case COMMO_INVALID_CACERT_PASSWORD: return "wrong CA certificate password";
    }
    return "unknown error";
}

std::string uidString(const ContactUID *c) {
    if (!c || !c->contactUID)
        return std::string();
    return std::string(reinterpret_cast<const char *>(c->contactUID), c->contactUIDLen);
}

std::string endpointOf(NetInterface *iface) {
    auto *streaming = dynamic_cast<StreamingNetInterface *>(iface);
    if (!streaming || !streaming->remoteEndpointId)
        return std::string();
    return std::string(streaming->remoteEndpointId, streaming->remoteEndpointLen);
}

// Every listener commo takes, as one object.
class Forwarder final : public CommoLogger,
                        public CoTMessageListener,
                        public ContactPresenceListener,
                        public InterfaceStatusListener {
public:
    explicit Forwarder(const mactak_commo_callbacks &cb) : cb(cb) {}

    void log(Level level, Type, const char *message, void *) override {
        if (cb.log)
            cb.log(cb.context, static_cast<int>(level), message ? message : "");
    }
    void cotMessageReceived(const char *xml, const char *endpoint) override {
        if (cb.cot_received)
            cb.cot_received(cb.context, xml ? xml : "", endpoint ? endpoint : "");
    }
    void contactAdded(const ContactUID *c) override {
        if (cb.contact_added)
            cb.contact_added(cb.context, uidString(c).c_str());
    }
    void contactRemoved(const ContactUID *c) override {
        if (cb.contact_removed)
            cb.contact_removed(cb.context, uidString(c).c_str());
    }
    void interfaceUp(NetInterface *iface) override {
        if (cb.interface_up)
            cb.interface_up(cb.context, endpointOf(iface).c_str());
    }
    void interfaceDown(NetInterface *iface) override {
        if (cb.interface_down)
            cb.interface_down(cb.context, endpointOf(iface).c_str());
    }
    void interfaceError(NetInterface *iface, netinterfaceenums::NetInterfaceErrorCode code) override {
        if (cb.interface_error)
            cb.interface_error(cb.context, endpointOf(iface).c_str(), static_cast<int>(code));
    }

private:
    const mactak_commo_callbacks cb;
};

// The third-party initialization commo's Java binding does in
// initNativeLibrariesNative. The libraries are commo's own dependencies, so
// they are loaded by the time commo is; looking the entry points up keeps
// this target free of libxml2, OpenSSL and curl headers and link flags.
int initLibraries(std::string &error) {
    using XmlInit = void (*)();
    using SslInit = int (*)(uint64_t, const void *);
    using CurlInit = int (*)(long);
    auto xmlInit = reinterpret_cast<XmlInit>(dlsym(RTLD_DEFAULT, "xmlInitParser"));
    auto sslInit = reinterpret_cast<SslInit>(dlsym(RTLD_DEFAULT, "OPENSSL_init_ssl"));
    auto curlInit = reinterpret_cast<CurlInit>(dlsym(RTLD_DEFAULT, "curl_global_init"));
    if (!xmlInit || !sslInit || !curlInit) {
        error = "libxml2, OpenSSL or curl is not loaded (is libcommoncommo linked?)";
        return -1;
    }
    xmlInit();
    // OPENSSL_INIT_LOAD_SSL_STRINGS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS: what
    // the binding's SSL_load_error_strings() expands to in OpenSSL 3.
    const uint64_t loadErrorStrings = 0x00200000L | 0x00000002L;
    if (!sslInit(loadErrorStrings, nullptr)) {
        error = "OPENSSL_init_ssl failed";
        return -1;
    }
    const long curlGlobalNothing = 0;
    if (curlInit(curlGlobalNothing) != 0) {
        error = "curl_global_init failed";
        return -1;
    }
    return 0;
}

}  // namespace

struct mactak_commo {
    Forwarder forwarder;
    Commo *commo = nullptr;
    std::mutex lock;   // guards streams
    std::map<std::string, StreamingNetInterface *> streams;

    explicit mactak_commo(const mactak_commo_callbacks &cb) : forwarder(cb) {}
};

extern "C" int mactak_commo_init_libraries(char *err, size_t errlen) {
    static std::once_flag once;
    static int result = -1;
    static std::string error;
    std::call_once(once, [] { result = initLibraries(error); });
    if (result != 0)
        setError(err, errlen, error);
    return result;
}

extern "C" mactak_commo *mactak_commo_create(const char *uid, const char *callsign,
                                             const mactak_commo_callbacks *callbacks,
                                             char *err, size_t errlen) {
    if (!uid || !*uid || !callsign || !callbacks) {
        setError(err, errlen, "a uid, a callsign and callbacks are required");
        return nullptr;
    }
    auto *shim = new mactak_commo(*callbacks);
    try {
        // Commo copies the uid and callsign.
        ContactUID ourUid(reinterpret_cast<const uint8_t *>(uid), std::strlen(uid));
        shim->commo = new Commo(&shim->forwarder, &ourUid, callsign);
        shim->commo->addInterfaceStatusListener(&shim->forwarder);
        shim->commo->addContactPresenceListener(&shim->forwarder);
        shim->commo->addCoTMessageListener(&shim->forwarder);
        return shim;
    } catch (const std::exception &e) {
        setError(err, errlen, std::string("creating Commo failed: ") + e.what());
    } catch (...) {
        setError(err, errlen, "creating Commo failed");
    }
    mactak_commo_destroy(shim);
    return nullptr;
}

extern "C" int mactak_commo_add_streaming(mactak_commo *shim, int transport,
                                          const char *host, int port,
                                          const uint8_t *cert, size_t cert_len,
                                          const uint8_t *ca, size_t ca_len,
                                          const char *cert_password, const char *ca_password,
                                          char *endpoint, size_t endpoint_len,
                                          char *err, size_t errlen) {
    if (!shim || !host) {
        setError(err, errlen, "no commo or no host");
        return -1;
    }
    const bool ssl = transport == MACTAK_COMMO_SSL;
    if (!ssl && transport != MACTAK_COMMO_TCP) {
        setError(err, errlen, "unknown transport " + std::to_string(transport));
        return -1;
    }
    if (ssl && (!cert || !cert_len || !ca || !ca_len || !cert_password || !ca_password)) {
        setError(err, errlen, "SSL needs a client certificate, a CA and both passwords");
        return -1;
    }
    const CoTMessageType types[] = {SITUATIONAL_AWARENESS, CHAT};
    try {
        CommoResult rc = COMMO_SUCCESS;
        StreamingNetInterface *iface = shim->commo->addStreamingInterface(
            ssl ? netinterfaceenums::TRANSPORT_SSL : netinterfaceenums::TRANSPORT_TCP,
            host, port, types, sizeof types / sizeof types[0],
            ssl ? cert : nullptr, ssl ? cert_len : 0,
            ssl ? ca : nullptr, ssl ? ca_len : 0,
            ssl ? cert_password : nullptr, ssl ? ca_password : nullptr,
            nullptr, nullptr, &rc);
        if (!iface) {
            setError(err, errlen, std::string("addStreamingInterface: ") + resultName(rc));
            return -1;
        }
        const std::string id(iface->remoteEndpointId, iface->remoteEndpointLen);
        {
            std::lock_guard<std::mutex> guard(shim->lock);
            shim->streams[id] = iface;
        }
        if (endpoint && endpoint_len > 0)
            std::snprintf(endpoint, endpoint_len, "%s", id.c_str());
        return 0;
    } catch (const std::exception &e) {
        setError(err, errlen, std::string("addStreamingInterface threw: ") + e.what());
    } catch (...) {
        setError(err, errlen, "addStreamingInterface threw");
    }
    return -1;
}

extern "C" int mactak_commo_remove_streaming(mactak_commo *shim, const char *endpoint,
                                             char *err, size_t errlen) {
    if (!shim || !endpoint) {
        setError(err, errlen, "no commo or no endpoint");
        return -1;
    }
    StreamingNetInterface *iface = nullptr;
    {
        std::lock_guard<std::mutex> guard(shim->lock);
        auto it = shim->streams.find(endpoint);
        if (it != shim->streams.end()) {
            iface = it->second;
            shim->streams.erase(it);
        }
    }
    if (!iface) {
        setError(err, errlen, std::string("no streaming interface ") + endpoint);
        return -1;
    }
    try {
        CommoResult rc = shim->commo->removeStreamingInterface(iface);
        if (rc == COMMO_SUCCESS)
            return 0;
        setError(err, errlen, std::string("removeStreamingInterface: ") + resultName(rc));
    } catch (...) {
        setError(err, errlen, "removeStreamingInterface threw");
    }
    return -1;
}

extern "C" int mactak_commo_broadcast(mactak_commo *shim, const char *xml,
                                      char *err, size_t errlen) {
    if (!shim || !xml) {
        setError(err, errlen, "no commo or no message");
        return -1;
    }
    try {
        CommoResult rc = shim->commo->broadcastCoT(xml);
        if (rc == COMMO_SUCCESS)
            return 0;
        setError(err, errlen, std::string("broadcastCoT: ") + resultName(rc));
    } catch (...) {
        setError(err, errlen, "broadcastCoT threw");
    }
    return -1;
}

extern "C" int mactak_commo_send(mactak_commo *shim, const char *const *uids, size_t count,
                                 const char *xml, char *err, size_t errlen) {
    if (!shim || !xml || (count > 0 && !uids)) {
        setError(err, errlen, "no commo, no message or no uids");
        return -1;
    }
    try {
        std::vector<ContactUID *> owned;
        owned.reserve(count);
        for (size_t i = 0; i < count; i++)
            owned.push_back(new ContactUID(reinterpret_cast<const uint8_t *>(uids[i]),
                                           std::strlen(uids[i])));
        std::vector<const ContactUID *> contacts(owned.begin(), owned.end());
        ContactList list(count, contacts.data());
        CommoResult rc = shim->commo->sendCoT(&list, xml);
        std::string gone;
        if (rc == COMMO_CONTACT_GONE) {   // commo moved the unreachable ones to the front
            for (size_t i = 0; i < list.nContacts; i++)
                gone += (i ? ", " : "") + uidString(list.contacts[i]);
        }
        for (ContactUID *c : owned)
            delete c;
        if (rc == COMMO_SUCCESS)
            return 0;
        setError(err, errlen, std::string("sendCoT: ") + resultName(rc)
                 + (gone.empty() ? "" : " (" + gone + ")"));
    } catch (...) {
        setError(err, errlen, "sendCoT threw");
    }
    return -1;
}

extern "C" void mactak_commo_destroy(mactak_commo *shim) {
    if (!shim)
        return;
    if (shim->commo) {
        try {
            // shutdown() returns once no listener can be called again.
            shim->commo->shutdown();
            delete shim->commo;
        } catch (...) {
            // Nothing a caller could do; the listeners are released either way.
        }
    }
    delete shim;
}
