// stdlib
#include <assert.h>
#include <cstddef>
#include <cstdint>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
// system
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/ip.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
// C++
#include <string>
#include <vector>
// proj
#include "hashtable.h"

#define container_of(ptr, T, member) ((T *)((char *)ptr - offsetof(T, member)))

static void msg(const char *msg) { fprintf(stderr, "%s\n", msg); }

static void msg_errno(const char *msg) {
  fprintf(stderr, "[errno:%d] %s\n", errno, msg);
}

static void die(const char *msg) {
  fprintf(stderr, "[%d] %s\n", errno, msg);
  abort();
}

static void fd_set_nb(int fd) {
  errno = 0;
  int flags = fcntl(fd, F_GETFL, 0);
  if (errno) {
    die("fcntl error");
    return;
  }

  flags |= O_NONBLOCK;

  errno = 0;
  (void)fcntl(fd, F_SETFL, flags);
  if (errno) {
    die("fcntl error");
  }
}

const size_t k_max_msg = 32 << 20;

typedef std::vector<uint8_t> Buffer;

struct Conn {
  int fd = -1;
  // app's intentions, for event loop
  bool want_read = false;
  bool want_write = false;
  bool want_close = false;
  // buffered input and output
  std::vector<uint8_t> incoming; // represents request
  std::vector<uint8_t> outgoing; // represents response
};

// append to the back
static void buf_append(std::vector<uint8_t> &buf, const uint8_t *data,
                       size_t len) {
  buf.insert(buf.end(), data, data + len);
}

// remove from the front
static void buf_consume(std::vector<uint8_t> &buf, size_t n) {
  buf.erase(buf.begin(), buf.begin() + n);
}

// application callback when the listening socket is ready
static Conn *handle_accept(int fd) {
  // accept
  struct sockaddr_in client_addr = {};
  socklen_t socklen = sizeof(client_addr);
  int connfd = accept(fd, (struct sockaddr *)&client_addr, &socklen);
  if (connfd < 0) {
    msg_errno("accept() error");
    return NULL;
  }

  uint32_t ip = client_addr.sin_addr.s_addr;
  fprintf(stderr, "new client from %u.%u.%u.%u:%u\n", ip & 255, (ip >> 8) & 255,
          (ip >> 16) & 255, ip >> 24, ntohs(client_addr.sin_port));

  // set the new fd to non-blocking
  fd_set_nb(connfd);

  // create a struct connection
  Conn *conn = new Conn();
  conn->fd = connfd;
  conn->want_read = true;
  return conn;
}

const size_t k_max_args = 200 * 1000;

static bool read_u32(const uint8_t *&cur, const uint8_t *end, uint32_t &out) {
  if (cur + 4 > end) {
    return false;
  }

  memcpy(&out, cur, 4);
  cur += 4;
  return true;
}

static bool read_str(const uint8_t *&cur, const uint8_t *end, size_t n,
                     std::string &out) {
  if (cur + n > end) {
    return false;
  }

  out.assign(cur, cur + n);
  cur += n;
  return true;
}

// +------+-----+------+-----+------+-----+-----+------+
// | nstr | len | str1 | len | str2 | ... | len | strn |
// +------+-----+------+-----+------+-----+-----+------+

static int32_t parse_req(const uint8_t *data, size_t size,
                         std::vector<std::string> &out) {
  const uint8_t *end = data + size;
  uint32_t nstr = 0;

  if (!read_u32(data, end, nstr)) {
    return -1; // safety limit
  }

  while (out.size() < nstr) {
    uint32_t len = 0;
    if (!read_u32(data, end, len)) {
      return -1;
    }
    out.push_back(std::string());

    if (!read_str(data, end, len, out.back())) {
      return -1;
    }
  }

  if (data != end) {
    return -1; // trailing garbage
  }

  return 0;
}

// error code for TAG_ERROR
enum {
  ERR_UNKNOWN = 1, // unknown command
  ERR_TOO_BIG = 2, // response too big
};

// data types for serialized data
enum {
  TAG_NIL = 0, // nil
  TAG_ERR = 1, // error code + msg
  TAG_STR = 2, // string
  TAG_INT = 3, // int64
  TAG_DBL = 4, // double
  TAG_ARR = 5, // array
};

static void buf_append_u8(Buffer &buf, uint8_t data) { buf.push_back(data); }

static void buf_append_u32(Buffer &buf, uint32_t data) {
  buf_append(buf, (const uint8_t *)&data, 4);
}

static void buf_append_i64(Buffer &buf, int64_t data) {
  buf_append(buf, (const uint8_t *)&data, 8);
}

static void buf_append_dbl(Buffer &buf, double data) {
  buf_append(buf, (const uint8_t *)&data, 8);
}

// append serialized data types to the back
static void out_nil(Buffer &out) { buf_append_u8(out, TAG_NIL); }

static void out_str(Buffer &out, const char *s, size_t size) {
  buf_append_u8(out, TAG_STR);
  buf_append_u32(out, (uint32_t)size);
  buf_append(out, (const uint8_t *)s, size);
}

static void out_int(Buffer &out, int64_t val) {
  buf_append_u8(out, TAG_INT);
  buf_append_i64(out, val);
}

static void out_dbl(Buffer &out, double val) {
  buf_append_u8(out, TAG_DBL);
  buf_append_dbl(out, val);
}

static void out_err(Buffer &out, uint32_t code, const std::string &msg) {
  buf_append_u8(out, TAG_ERR);
  buf_append_u32(out, code);
  buf_append_u32(out, (uint32_t)msg.size());
  buf_append(out, (const uint8_t *)msg.data(), msg.size());
}

static void out_arr(Buffer &out, uint32_t n) {
  buf_append_u8(out, TAG_ARR);
  buf_append_u32(out, n);
}

// global states
static struct {
  HMap db; // top-level hashtable
} g_data;

// kv pair for the top level hashtable
struct Entry {
  struct HNode node;
  std::string key;
  std::string val;
};

// equality comparison for `struct entry`
static bool entry_eq(HNode *lhs, HNode *rhs) {
  struct Entry *le = container_of(lhs, struct Entry, node);
  struct Entry *re = container_of(rhs, struct Entry, node);

  return le->key == re->key;
}

// FNV hash
static uint64_t str_hash(const uint8_t *data, size_t len) {
  uint32_t h = 0x811C9DC5;
  for (size_t i = 0; i < len; i++) {
    h = (h + data[i]) * 0x01000193;
  }
  return h;
}

static void do_get(std::vector<std::string> &cmd, Buffer &out) {
  // a dummy entry
  Entry key;
  key.key.swap(cmd[1]);
  key.node.hcode = str_hash((uint8_t *)key.key.data(), key.key.size());
  // hashtable lookup
  HNode *node = hm_lookup(&g_data.db, &key.node, &entry_eq);
  if (!node) {
    return out_nil(out);
  }

  // copy the value
  const std::string &val = container_of(node, Entry, node)->val;
  return out_str(out, val.data(), val.size());
}

static void do_set(std::vector<std::string> &cmd, Buffer &out) {
  // a dummy `Entry` just for the lookup
  Entry key;
  key.key.swap(cmd[1]);
  key.node.hcode = str_hash((uint8_t *)key.key.data(), key.key.size());
  // hashtable lookup
  HNode *node = hm_lookup(&g_data.db, &key.node, &entry_eq);
  if (node) {
    // found, update the value
    container_of(node, Entry, node)->val.swap(cmd[2]);
  } else {
    // not found, allocate & insert a new pair
    Entry *ent = new Entry();
    ent->key.swap(key.key);
    ent->node.hcode = key.node.hcode;
    ent->val.swap(cmd[2]);
    hm_insert(&g_data.db, &ent->node);
  }
  return out_nil(out);
}

static void do_del(std::vector<std::string> &cmd, Buffer &out) {
  // a dummy `Entry` just for the lookup
  Entry key;
  key.key.swap(cmd[1]);
  key.node.hcode = str_hash((uint8_t *)key.key.data(), key.key.size());
  // hashtable delete
  HNode *node = hm_delete(&g_data.db, &key.node, &entry_eq);
  if (node) { // deallocate the pair
    delete container_of(node, Entry, node);
  }
  return out_int(out, node ? 1 : 0);
}

static bool cb_keys(HNode *node, void *arg) {
  Buffer &out = *(Buffer *)arg;
  const std::string &key = container_of(node, Entry, node)->key;
  out_str(out, key.data(), key.size());
  return true;
}

static void do_keys(std::vector<std::string> &, Buffer &out) {
  out_arr(out, (uint32_t)hm_size(&g_data.db));
  hm_foreach(&g_data.db, &cb_keys, (void *)&out);
}

static void do_request(std::vector<std::string> &cmd, Buffer &out) {
  if (cmd.size() == 2 && cmd[0] == "get") {
    return do_get(cmd, out);
  } else if (cmd.size() == 3 && cmd[0] == "set") {
    return do_set(cmd, out);
  } else if (cmd.size() == 2 && cmd[0] == "del") {
    return do_del(cmd, out);
  } else if (cmd.size() == 1 && cmd[0] == "keys") {
    return do_keys(cmd, out);
  } else {
    return out_err(out, ERR_UNKNOWN, "unknown command");
  }
}

static void response_begin(Buffer &out, size_t *header) {
  *header = out.size();   // messege header position
  buf_append_u32(out, 0); // reserve space
}

static size_t response_size(Buffer &out, size_t header) {
  return out.size() - header - 4;
}

static void response_end(Buffer &out, size_t header) {
  size_t msg_size = response_size(out, header);
  if (msg_size > k_max_msg) {
    out.resize(header + 4);
    out_err(out, ERR_TOO_BIG, "response is too big.");
    msg_size = response_size(out, header);
  }
  // message header
  uint32_t len = (uint32_t)msg_size;
  memcpy(&out[header], &len, 4);
}

// process one request if there is enough data
static bool try_one_request(Conn *conn) {
  // try to parse the protocol: message header
  if (conn->incoming.size() < 4) {
    return false; // want read
  }
  uint32_t len = 0;
  memcpy(&len, conn->incoming.data(), 4);
  if (len > k_max_msg) {
    msg("too long");
    conn->want_close = true;
    return false; // want close
  }

  // message body
  if (4 + len > conn->incoming.size()) {
    return false; // want read
  }
  const uint8_t *request = &conn->incoming[4];

  // got one req, perform app logic
  std::vector<std::string> cmd;
  if (parse_req(request, len, cmd) < 0) {
    msg("bad request");
    conn->want_close = true;
    return false; // want close
  }

  size_t header_pos = 0;
  response_begin(conn->outgoing, &header_pos);
  do_request(cmd, conn->outgoing);
  response_end(conn->outgoing, header_pos);

  // app logic done, remove the req message
  buf_consume(conn->incoming, 4 + len);

  return true; // success
}

// app callback when the socket is writable
static void handle_write(Conn *conn) {
  assert(conn->outgoing.size() > 0);
  ssize_t rv = write(conn->fd, &conn->outgoing[0], conn->outgoing.size());
  if (rv < 0 && errno == EAGAIN) {
    return; // actually not ready
  }

  if (rv < 0) {
    msg_errno("write() error");
    conn->want_close = true;
    return;
  }

  // remove written data from outgoing
  buf_consume(conn->outgoing, (size_t)rv);

  // update the readiness intention
  if (conn->outgoing.size() == 0) {
    // all data is written
    conn->want_read = true;
    conn->want_write = false;
  } // else: want write
}

// app callback when the socket is readable
static void handle_read(Conn *conn) {
  // read some data
  uint8_t buf[64 * 1024];
  ssize_t rv = read(conn->fd, buf, sizeof(buf));
  if (rv < 0 && errno == EAGAIN) {
    return; // actually not ready
  }

  // handle IO error
  if (rv < 0) {
    msg_errno("read() error");
    conn->want_close = true;
    return; // want close
  }

  // handle EOF
  if (rv == 0) {
    if (conn->incoming.size() == 0) {
      msg("client closed");
    } else {
      msg("unexpected EOF");
    }
    conn->want_close = true;
    return; // want close
  }

  // got some new data
  buf_append(conn->incoming, buf, (size_t)rv);

  // parse req and generate response
  while (try_one_request(conn)) {
  }

  // update the readiness intention
  if (conn->outgoing.size() > 0) {
    conn->want_read = false;
    conn->want_write = true;

    // the socket is likely ready to write in a req-res protocol,
    // try to write it without waiting for the next iteration
    return handle_write(conn);
  } // else: want read
}

int main() {
  // the listening socket
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    die("socket()");
  }

  int val = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &val, sizeof(val));

  // bind
  struct sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(1234);
  addr.sin_addr.s_addr = htonl(0);
  int rv = bind(fd, (const sockaddr *)&addr, sizeof(addr));
  if (rv) {
    die("bind()");
  }

  // set the fd to non blocking
  fd_set_nb(fd);

  // listen
  rv = listen(fd, SOMAXCONN);
  if (rv) {
    die("listen()");
  }

  // a map of all client connections, keyed by fd
  std::vector<Conn *> fd2conn;

  // the event loop
  std::vector<struct pollfd> poll_args;

  while (true) {
    // prepare the args for `poll()`
    poll_args.clear();

    // put the listening socket in the first position
    struct pollfd pfd = {fd, POLLIN, 0};
    poll_args.push_back(pfd);

    // the rest are connection sockets
    for (Conn *conn : fd2conn) {
      if (!conn) {
        continue;
      }

      // always poll() for error
      struct pollfd pfd = {conn->fd, POLLERR, 0};

      // poll() flags from the app's intent
      if (conn->want_read) {
        pfd.events |= POLLIN;
      }

      if (conn->want_write) {
        pfd.events |= POLLOUT;
      }

      poll_args.push_back(pfd);
    }

    // wait for readiness
    int rv = poll(poll_args.data(), (nfds_t)poll_args.size(), -1);
    if (rv < 0 && errno == EINTR) {
      continue; // not an error
    }

    if (rv < 0) {
      die("poll");
    }

    // handle the listening socket
    if (poll_args[0].revents) {
      if (Conn *conn = handle_accept(fd)) {
        // put it into the map
        if (fd2conn.size() <= (size_t)conn->fd) {
          fd2conn.resize(conn->fd + 1);
        }
        assert(!fd2conn[conn->fd]);
        fd2conn[conn->fd] = conn;
      }
    }

    // handle connections sockets
    for (size_t i = 1; i < poll_args.size(); ++i) { // note: skip the first
      uint32_t ready = poll_args[i].revents;
      if (ready == 0) {
        continue;
      }

      Conn *conn = fd2conn[poll_args[i].fd];

      if (ready & POLLIN) {
        assert(conn->want_read);
        handle_read(conn);
      }

      if (ready & POLLOUT) {
        assert(conn->want_write);
        handle_write(conn);
      }

      // close the socket from socket error or app logic
      if ((ready & POLLERR) || conn->want_close) {
        (void)close(conn->fd);
        fd2conn[conn->fd] = NULL;
        delete conn;
      }
    } // for each connection socket
  }   // the event loop

  return 0;
}
