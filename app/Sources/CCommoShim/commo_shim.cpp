// commo_shim.cpp — commo's listeners forwarded to C callbacks (commo_shim.h).

#include "commo_shim.h"

#include <commo.h>
#include <curl/curl.h>

#include <dlfcn.h>
#include <signal.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <map>
#include <stdexcept>
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
                        public InterfaceStatusListener,
                        public EnrollmentIO {
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
        report(iface, {Status::up, 0});
    }
    void interfaceDown(NetInterface *iface) override {
        report(iface, {Status::down, 0});
    }
    void interfaceError(NetInterface *iface, netinterfaceenums::NetInterfaceErrorCode code) override {
        report(iface, {Status::error, static_cast<int>(code)});
    }
    void enrollmentUpdate(const EnrollmentIOUpdate *u) override {
        if (!cb.enrollment_update || !u)
            return;
        // keygen's success carries the private key as PEM: never passed out.
        const bool signed_ = u->step == ENROLL_STEP_SIGN && u->status == FILEIO_SUCCESS;
        cb.enrollment_update(cb.context, u->xferid, static_cast<int>(u->step),
                             static_cast<int>(u->status),
                             u->additionalInfo ? u->additionalInfo : "",
                             signed_ ? u->privResult : nullptr, signed_ ? u->privResultLen : 0,
                             signed_ ? u->caResult : nullptr, signed_ ? u->caResultLen : 0);
    }

    // A mesh interface's id, known once its add call returns. commo can
    // report the interface before that (from its own threads), so until then
    // its statuses wait here and are replayed, in order, by registerMesh.
    void registerMesh(NetInterface *iface, const std::string &id) {
        std::lock_guard<std::mutex> guard(meshLock);
        meshIds[iface] = id;
        auto early = pending.find(iface);
        if (early == pending.end())
            return;
        for (const StatusEvent &event : early->second)
            forward(id, event);
        pending.erase(early);
    }
    void forgetMesh(NetInterface *iface) {
        std::lock_guard<std::mutex> guard(meshLock);
        meshIds.erase(iface);
        pending.erase(iface);
    }

private:
    enum class Status { up, down, error };
    struct StatusEvent {
        Status status;
        int code;
    };

    void report(NetInterface *iface, StatusEvent event) {
        if (dynamic_cast<StreamingNetInterface *>(iface)) {
            forward(endpointOf(iface), event);
            return;
        }
        // Forwarded under the lock, so a replay and a later status keep
        // their order. The lock is ours alone: commo never waits on it.
        std::lock_guard<std::mutex> guard(meshLock);
        auto known = meshIds.find(iface);
        if (known != meshIds.end())
            forward(known->second, event);
        else
            pending[iface].push_back(event);
    }
    void forward(const std::string &id, StatusEvent event) {
        switch (event.status) {
            case Status::up:
                if (cb.interface_up)
                    cb.interface_up(cb.context, id.c_str());
                break;
            case Status::down:
                if (cb.interface_down)
                    cb.interface_down(cb.context, id.c_str());
                break;
            case Status::error:
                if (cb.interface_error)
                    cb.interface_error(cb.context, id.c_str(), event.code);
                break;
        }
    }

    const mactak_commo_callbacks cb;
    std::mutex meshLock;   // guards meshIds and pending
    std::map<NetInterface *, std::string> meshIds;
    std::map<NetInterface *, std::vector<StatusEvent>> pending;
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
    // commo writes to its sockets with no SO_NOSIGPIPE or MSG_NOSIGNAL, so a
    // write to a peer that has closed (a server refusing our certificate)
    // raises SIGPIPE, which kills a process that hasn't ignored it. The JVM
    // ignores it, which hid this through G1; a Swift process doesn't
    // (dev/g3/NOTES.md, trap 4). Ignored, the write fails with EPIPE and
    // commo reconnects.
    signal(SIGPIPE, SIG_IGN);
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

// One of the interfaces mactak_commo_add_inbound, _add_broadcast and
// _add_tcp_inbound create: commo removes each kind with its own call.
struct MeshInterface {
    enum class Kind { inbound, broadcast, tcpInbound } kind;
    NetInterface *iface;
};

}  // namespace

struct mactak_commo {
    Forwarder forwarder;
    Commo *commo = nullptr;
    std::mutex lock;   // guards streams and mesh
    std::map<std::string, StreamingNetInterface *> streams;
    std::map<std::string, MeshInterface> mesh;

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
        // Interfaces by name ("en0", "lo0"), as ATAK names them; by MAC
        // address, the default, lo0 could not be named (it has none).
        shim->commo = new Commo(&shim->forwarder, &ourUid, callsign,
                                netinterfaceenums::MODE_NAME);
        shim->commo->addInterfaceStatusListener(&shim->forwarder);
        shim->commo->addContactPresenceListener(&shim->forwarder);
        shim->commo->addCoTMessageListener(&shim->forwarder);
        CommoResult rc = shim->commo->enableEnrollment(&shim->forwarder);
        if (rc != COMMO_SUCCESS)
            throw std::runtime_error(std::string("enableEnrollment: ") + resultName(rc));
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
    netinterfaceenums::StreamingTransport kind;
    switch (transport) {
        case MACTAK_COMMO_TCP: kind = netinterfaceenums::TRANSPORT_TCP; break;
        case MACTAK_COMMO_SSL: kind = netinterfaceenums::TRANSPORT_SSL; break;
        case MACTAK_COMMO_QUIC: kind = netinterfaceenums::TRANSPORT_QUIC; break;
        default:
            setError(err, errlen, "unknown transport " + std::to_string(transport));
            return -1;
    }
    const bool ssl = transport != MACTAK_COMMO_TCP;   // SSL and QUIC both carry TLS
    if (ssl && (!cert || !cert_len || !ca || !ca_len || !cert_password || !ca_password)) {
        setError(err, errlen, "SSL and QUIC need a client certificate, a CA and both passwords");
        return -1;
    }
    const CoTMessageType types[] = {SITUATIONAL_AWARENESS, CHAT};
    try {
        CommoResult rc = COMMO_SUCCESS;
        StreamingNetInterface *iface = shim->commo->addStreamingInterface(
            kind, host, port, types, sizeof types / sizeof types[0],
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

namespace {

// Record a mesh interface commo just created under id, and report the id.
int keepMesh(mactak_commo *shim, MeshInterface::Kind kind, NetInterface *iface,
             const std::string &id, char *endpoint, size_t endpoint_len) {
    {
        std::lock_guard<std::mutex> guard(shim->lock);
        shim->mesh[id] = MeshInterface{kind, iface};
    }
    shim->forwarder.registerMesh(iface, id);
    if (endpoint && endpoint_len > 0)
        std::snprintf(endpoint, endpoint_len, "%s", id.c_str());
    return 0;
}

bool meshIdTaken(mactak_commo *shim, const std::string &id, char *err, size_t errlen) {
    std::lock_guard<std::mutex> guard(shim->lock);
    if (shim->mesh.count(id) == 0)
        return false;
    setError(err, errlen, "mesh interface " + id + " already exists");
    return true;
}

}  // namespace

extern "C" int mactak_commo_set_mesh_options(mactak_commo *shim, int ttl, int loopback,
                                             int address_reuse, char *err, size_t errlen) {
    if (!shim) {
        setError(err, errlen, "no commo");
        return -1;
    }
    if (ttl < 1 || ttl > 255) {
        setError(err, errlen, "a multicast TTL is 1 to 255, not " + std::to_string(ttl));
        return -1;
    }
    try {
        shim->commo->setTTL(ttl);
        shim->commo->setMulticastLoopbackEnabled(loopback != 0);
        shim->commo->setEnableAddressReuse(address_reuse != 0);
        return 0;
    } catch (...) {
        setError(err, errlen, "setting the mesh options threw");
    }
    return -1;
}

extern "C" int mactak_commo_add_inbound(mactak_commo *shim, const char *ifname, int port,
                                        const char *const *groups, size_t group_count,
                                        char *endpoint, size_t endpoint_len,
                                        char *err, size_t errlen) {
    if (!shim || !ifname || !*ifname || (group_count > 0 && !groups)) {
        setError(err, errlen, "no commo, no interface name or no groups");
        return -1;
    }
    const std::string id = std::string("in:") + ifname + ":" + std::to_string(port);
    if (meshIdTaken(shim, id, err, errlen))
        return -1;
    try {
        HwAddress name(reinterpret_cast<const uint8_t *>(ifname), std::strlen(ifname));
        std::vector<const char *> list(groups, groups + group_count);
        PhysicalNetInterface *iface = shim->commo->addInboundInterface(
            &name, port, group_count ? list.data() : nullptr, group_count, false);
        if (!iface) {
            setError(err, errlen, "addInboundInterface refused " + id
                     + " (port in use or out of range, or a group not multicast)");
            return -1;
        }
        return keepMesh(shim, MeshInterface::Kind::inbound, iface, id, endpoint, endpoint_len);
    } catch (...) {
        setError(err, errlen, "addInboundInterface threw");
    }
    return -1;
}

extern "C" int mactak_commo_add_broadcast(mactak_commo *shim, const char *ifname, int kind,
                                          const char *group, int port,
                                          char *endpoint, size_t endpoint_len,
                                          char *err, size_t errlen) {
    if (!shim || !ifname || !*ifname || !group) {
        setError(err, errlen, "no commo, no interface name or no group");
        return -1;
    }
    CoTMessageType type;
    switch (kind) {
        case MACTAK_COMMO_SA: type = SITUATIONAL_AWARENESS; break;
        case MACTAK_COMMO_CHAT: type = CHAT; break;
        default:
            setError(err, errlen, "unknown message kind " + std::to_string(kind));
            return -1;
    }
    const std::string id = std::string("out:") + ifname + ":" + group + ":" + std::to_string(port);
    if (meshIdTaken(shim, id, err, errlen))
        return -1;
    try {
        HwAddress name(reinterpret_cast<const uint8_t *>(ifname), std::strlen(ifname));
        PhysicalNetInterface *iface = shim->commo->addBroadcastInterface(&name, &type, 1, group, port);
        if (!iface) {
            setError(err, errlen, "addBroadcastInterface refused " + id
                     + " (not a multicast group, or port out of range)");
            return -1;
        }
        return keepMesh(shim, MeshInterface::Kind::broadcast, iface, id, endpoint, endpoint_len);
    } catch (...) {
        setError(err, errlen, "addBroadcastInterface threw");
    }
    return -1;
}

extern "C" int mactak_commo_add_tcp_inbound(mactak_commo *shim, int port,
                                            char *endpoint, size_t endpoint_len,
                                            char *err, size_t errlen) {
    if (!shim) {
        setError(err, errlen, "no commo");
        return -1;
    }
    const std::string id = "tcp:" + std::to_string(port);
    if (meshIdTaken(shim, id, err, errlen))
        return -1;
    try {
        TcpInboundNetInterface *iface = shim->commo->addTcpInboundInterface(port);
        if (!iface) {
            setError(err, errlen, "addTcpInboundInterface refused port " + std::to_string(port)
                     + " (in use or out of range)");
            return -1;
        }
        return keepMesh(shim, MeshInterface::Kind::tcpInbound, iface, id, endpoint, endpoint_len);
    } catch (...) {
        setError(err, errlen, "addTcpInboundInterface threw");
    }
    return -1;
}

extern "C" int mactak_commo_remove_mesh(mactak_commo *shim, const char *endpoint,
                                        char *err, size_t errlen) {
    if (!shim || !endpoint) {
        setError(err, errlen, "no commo or no endpoint");
        return -1;
    }
    MeshInterface found{};
    bool known = false;
    {
        std::lock_guard<std::mutex> guard(shim->lock);
        auto it = shim->mesh.find(endpoint);
        if (it != shim->mesh.end()) {
            found = it->second;
            known = true;
            shim->mesh.erase(it);
        }
    }
    if (!known) {
        setError(err, errlen, std::string("no mesh interface ") + endpoint);
        return -1;
    }
    try {
        CommoResult rc = COMMO_ILLEGAL_ARGUMENT;
        switch (found.kind) {
            case MeshInterface::Kind::inbound:
                rc = shim->commo->removeInboundInterface(static_cast<PhysicalNetInterface *>(found.iface));
                break;
            case MeshInterface::Kind::broadcast:
                rc = shim->commo->removeBroadcastInterface(static_cast<PhysicalNetInterface *>(found.iface));
                break;
            case MeshInterface::Kind::tcpInbound:
                rc = shim->commo->removeTcpInboundInterface(static_cast<TcpInboundNetInterface *>(found.iface));
                break;
        }
        // commo reports nothing for it after its remove call returns.
        shim->forwarder.forgetMesh(found.iface);
        if (rc == COMMO_SUCCESS)
            return 0;
        setError(err, errlen, std::string("removing ") + endpoint + ": " + resultName(rc));
    } catch (...) {
        setError(err, errlen, std::string("removing ") + endpoint + " threw");
    }
    return -1;
}

extern "C" int mactak_commo_enroll_init(mactak_commo *shim, const char *host, int port, int verify_host,
                                        const char *user, const char *password, int use_token,
                                        const uint8_t *ca, size_t ca_len, const char *ca_password,
                                        const char *identity_password, const char *trust_password,
                                        const char *key_password, int key_bits, const char *version,
                                        int *enrollment, char *err, size_t errlen) {
    if (!shim || !host || !user || !password || !enrollment || !identity_password
        || !trust_password || !key_password) {
        setError(err, errlen, "enrollment needs a host, a user, a password, three passwords and an id");
        return -1;
    }
    if (!ca || !ca_len || !ca_password) {
        // With no CA, commo's enrollment accepts any server certificate
        // (#146, make test-commo-https): never let that happen by default.
        setError(err, errlen, "enrollment needs the CA the server must chain to");
        return -1;
    }
    try {
        CommoResult rc = shim->commo->enrollmentInit(
            enrollment, host, port, verify_host != 0, user, password, use_token != 0,
            ca, ca_len, ca_password, identity_password, trust_password, key_password,
            key_bits, version ? version : "");
        if (rc == COMMO_SUCCESS)
            return 0;
        setError(err, errlen, std::string("enrollmentInit: ") + resultName(rc));
    } catch (const std::exception &e) {
        setError(err, errlen, std::string("enrollmentInit threw: ") + e.what());
    } catch (...) {
        setError(err, errlen, "enrollmentInit threw");
    }
    return -1;
}

extern "C" int mactak_commo_enroll_start(mactak_commo *shim, int enrollment, char *err, size_t errlen) {
    if (!shim) {
        setError(err, errlen, "no commo");
        return -1;
    }
    try {
        CommoResult rc = shim->commo->enrollmentStart(enrollment);
        if (rc == COMMO_SUCCESS)
            return 0;
        setError(err, errlen, std::string("enrollmentStart: ") + resultName(rc));
    } catch (...) {
        setError(err, errlen, "enrollmentStart threw");
    }
    return -1;
}

namespace {

struct Download {
    std::vector<uint8_t> body;
    size_t limit;
    bool overflowed = false;
};

size_t collect(char *data, size_t size, size_t count, void *context) {
    auto *download = static_cast<Download *>(context);
    const size_t n = size * count;
    if (download->body.size() + n > download->limit) {
        download->overflowed = true;
        return 0;   // curl stops with CURLE_WRITE_ERROR
    }
    download->body.insert(download->body.end(), data, data + n);
    return n;
}

}  // namespace

extern "C" int mactak_commo_https_get(const char *url, const char *user, const char *password,
                                      const uint8_t *ca_pem, size_t ca_len, int verify_host,
                                      size_t max_bytes, long timeout_s,
                                      long *status, uint8_t **body, size_t *body_len,
                                      char *err, size_t errlen) {
    if (!url || !status || !body || !body_len) {
        setError(err, errlen, "a URL and places for the status and body are required");
        return -1;
    }
    if (!ca_pem || !ca_len) {
        setError(err, errlen, "an https GET needs the CA the server must chain to");
        return -1;
    }
    CURL *curl = curl_easy_init();
    if (!curl) {
        setError(err, errlen, "curl_easy_init failed (is mactak_commo_init_libraries done?)");
        return -1;
    }
    Download download{{}, max_bytes};
    curl_blob ca{const_cast<uint8_t *>(ca_pem), ca_len, CURL_BLOB_COPY};
    // Only this CA: no compiled-in bundle or directory adds system roots.
    curl_easy_setopt(curl, CURLOPT_CAINFO, nullptr);
    curl_easy_setopt(curl, CURLOPT_CAPATH, nullptr);
    curl_easy_setopt(curl, CURLOPT_CAINFO_BLOB, &ca);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, verify_host ? 2L : 0L);
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "https");
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_s);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, collect);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &download);
    if (user) {
        curl_easy_setopt(curl, CURLOPT_HTTPAUTH, static_cast<long>(CURLAUTH_BASIC));
        curl_easy_setopt(curl, CURLOPT_USERNAME, user);
        curl_easy_setopt(curl, CURLOPT_PASSWORD, password ? password : "");
    }
    const CURLcode rc = curl_easy_perform(curl);
    long code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
    curl_easy_cleanup(curl);
    if (download.overflowed) {
        setError(err, errlen, "the response is larger than " + std::to_string(max_bytes) + " bytes");
        return -1;
    }
    if (rc != CURLE_OK) {
        setError(err, errlen, std::string(curl_easy_strerror(rc)) + " (CURLcode " + std::to_string(rc) + ")");
        return -1;
    }
    auto *out = static_cast<uint8_t *>(std::malloc(download.body.empty() ? 1 : download.body.size()));
    if (!out) {
        setError(err, errlen, "out of memory");
        return -1;
    }
    if (!download.body.empty())
        std::memcpy(out, download.body.data(), download.body.size());
    *status = code;
    *body = out;
    *body_len = download.body.size();
    return 0;
}

extern "C" void mactak_commo_free(void *pointer) {
    std::free(pointer);
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
